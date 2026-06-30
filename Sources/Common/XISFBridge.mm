#import "XISFBridge.h"
#include "libxisf.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <map>
#include <vector>

// ─────────────────────────────────────────────────────────────
// STF (PixInsight Screen Transfer Function)
// ─────────────────────────────────────────────────────────────
namespace {

inline float mtf(float m, float x) {
    if (x <= 0.0f) return 0.0f;
    if (x >= 1.0f) return 1.0f;
    if (std::abs(x - m) < 1e-7f) return 0.5f;
    return (m - 1.0f) * x / ((2.0f * m - 1.0f) * x - m);
}

struct STFParams { float c0, m; };

STFParams computeSTF(const float *data, size_t count, size_t stride = 8) {
    if (count == 0) return {0.0f, 0.5f};
    std::vector<float> s;
    s.reserve(count / stride + 1);
    for (size_t i = 0; i < count; i += stride) {
        float v = data[i];
        if (std::isfinite(v) && v >= 0.0f && v <= 1.0f) s.push_back(v);
    }
    if (s.empty()) return {0.0f, 0.5f};
    size_t mid = s.size() / 2;
    std::nth_element(s.begin(), s.begin() + mid, s.end());
    float med = s[mid];
    float mad = 0.0f;
    for (float v : s) mad += std::fabs(v - med);
    mad /= (float)s.size();
    float c0 = std::max(0.0f, std::min(1.0f, med + (-2.8f * mad)));
    float denom = 1.0f - c0;
    if (denom < 1e-7f) return {c0, 0.5f};
    return {c0, mtf(0.25f, (med - c0) / denom)};
}

inline float applySTF(float px, STFParams p) {
    if (px <= p.c0) return 0.0f;
    return std::max(0.0f, std::min(1.0f, mtf(p.m, (px - p.c0) / (1.0f - p.c0))));
}

// ─────────────────────────────────────────────────────────────
// XISF pixel extraction
// ─────────────────────────────────────────────────────────────

inline float sampleToFloat(const void *data, size_t idx, LibXISF::Image::SampleFormat fmt) {
    switch (fmt) {
        case LibXISF::Image::UInt8:   return ((const uint8_t  *)data)[idx] / 255.0f;
        case LibXISF::Image::UInt16:  return ((const uint16_t *)data)[idx] / 65535.0f;
        case LibXISF::Image::UInt32:  return ((const uint32_t *)data)[idx] / 4294967295.0f;
        case LibXISF::Image::Float32: return ((const float    *)data)[idx];
        case LibXISF::Image::Float64: return (float)((const double *)data)[idx];
        default: return 0.0f;
    }
}

std::vector<float> imageToFloatPlanar(const LibXISF::Image &img) {
    uint64_t w = img.width(), h = img.height(), ch = img.channelCount();
    uint64_t ppc = w * h;
    auto fmt = img.sampleFormat();
    const void *data = img.imageData();
    bool planar = (img.pixelStorage() == LibXISF::Image::Planar);
    std::vector<float> result(ppc * ch);
    for (uint64_t c = 0; c < ch; c++)
        for (uint64_t p = 0; p < ppc; p++) {
            size_t src = planar ? (c * ppc + p) : (p * ch + c);
            result[c * ppc + p] = sampleToFloat(data, src, fmt);
        }
    return result;
}

// ─────────────────────────────────────────────────────────────
// Image assembly (shared by XISF and FITS paths)
// ─────────────────────────────────────────────────────────────

NSImage *buildNSImage(uint64_t width, uint64_t height, uint64_t channels,
                      const std::vector<float> &px, const std::vector<STFParams> &params) {
    if (width == 0 || height == 0 || px.empty()) return nil;
    bool gray = (channels == 1);
    size_t bpp = gray ? 1 : 4;
    size_t bpr = width * bpp;
    uint64_t ppc = width * height;
    std::vector<uint8_t> buf(height * bpr);

    if (gray) {
        const float *ch0 = px.data();
        for (uint64_t y = 0; y < height; y++) {
            uint8_t *row = buf.data() + y * bpr;
            for (uint64_t x = 0; x < width; x++)
                row[x] = (uint8_t)(applySTF(ch0[y * width + x], params[0]) * 255.0f + 0.5f);
        }
    } else {
        const float *r = px.data(), *g = px.data() + ppc, *b = px.data() + ppc * 2;
        STFParams pr = params.size() > 0 ? params[0] : STFParams{0.0f, 0.5f};
        STFParams pg = params.size() > 1 ? params[1] : pr;
        STFParams pb = params.size() > 2 ? params[2] : pr;
        for (uint64_t y = 0; y < height; y++) {
            uint8_t *row = buf.data() + y * bpr;
            for (uint64_t x = 0; x < width; x++) {
                uint64_t p = y * width + x;
                row[x*4+0] = (uint8_t)(applySTF(r[p], pr) * 255.0f + 0.5f);
                row[x*4+1] = (uint8_t)(applySTF(g[p], pg) * 255.0f + 0.5f);
                row[x*4+2] = (uint8_t)(applySTF(b[p], pb) * 255.0f + 0.5f);
                row[x*4+3] = 255;
            }
        }
    }

    CGColorSpaceRef cs = gray ? CGColorSpaceCreateDeviceGray()
                              : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo bi = gray ? kCGImageAlphaNone
                           : (kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast);
    CFDataRef cfData = CFDataCreate(kCFAllocatorDefault, buf.data(), (CFIndex)buf.size());
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(cfData);
    CFRelease(cfData);
    CGImageRef cgImg = CGImageCreate((size_t)width, (size_t)height, 8, bpp * 8, bpr,
                                     cs, bi, provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (!cgImg) return nil;
    NSImage *result = [[NSImage alloc] initWithCGImage:cgImg
                                                  size:NSMakeSize((CGFloat)width, (CGFloat)height)];
    CGImageRelease(cgImg);
    return result;
}

NSImage *scaleToFit(NSImage *src, CGSize maxSize) {
    NSSize sz = src.size;
    if (sz.width == 0 || sz.height == 0) return src;
    CGFloat scale = std::min(maxSize.width / sz.width, maxSize.height / sz.height);
    if (scale >= 1.0) return src;
    NSSize dest = NSMakeSize(sz.width * scale, sz.height * scale);
    NSImage *scaled = [[NSImage alloc] initWithSize:dest];
    [scaled lockFocus];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    [src drawInRect:NSMakeRect(0, 0, dest.width, dest.height)
           fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
    [scaled unlockFocus];
    return scaled;
}

NSImage *decodeXISFImage(LibXISF::Image &img, bool applyStretch) {
    img.convertPixelStorageTo(LibXISF::Image::Planar);
    uint64_t w = img.width(), h = img.height();
    uint64_t ch = std::min(img.channelCount(), (uint64_t)3);
    auto px = imageToFloatPlanar(img);
    uint64_t ppc = w * h;
    std::vector<STFParams> params(ch);
    if (applyStretch)
        for (uint64_t c = 0; c < ch; c++)
            params[c] = computeSTF(px.data() + c * ppc, (size_t)ppc);
    else
        for (uint64_t c = 0; c < ch; c++)
            params[c] = {0.0f, 0.5f};
    return buildNSImage(w, h, ch, px, params);
}

} // anonymous namespace

// ─────────────────────────────────────────────────────────────
// Minimal FITS reader (uncompressed primary HDU, all BITPIX)
// ─────────────────────────────────────────────────────────────
namespace fits {

struct Header {
    int      bitpix   = 0;
    int64_t  width    = 0, height = 0, channels = 1;
    double   bscale   = 1.0, bzero = 0.0;
    size_t   dataOffset = 0;
    std::map<std::string, std::string> keywords;
    bool valid = false;
};

// Parse a single 80-byte FITS card into key + value strings.
// Returns false when the END card is reached.
static bool parseCard(const char *card, std::string &key, std::string &val) {
    // Key: positions 0–7, right-padded with spaces
    int kend = 8;
    while (kend > 0 && card[kend - 1] == ' ') --kend;
    key.assign(card, kend);
    if (key == "END") return false;

    val.clear();
    if (card[8] != '=') return true; // comment / history card

    // Value field starts at position 10; skip leading spaces
    int vs = 10;
    while (vs < 80 && card[vs] == ' ') ++vs;
    if (vs >= 80) return true;

    if (card[vs] == '\'') {
        // FITS string: terminated by an unescaped single-quote
        int ve = vs + 1;
        while (ve < 80) {
            if (card[ve] == '\'') {
                if (ve + 1 < 80 && card[ve + 1] == '\'') { ve += 2; continue; }
                break;
            }
            ++ve;
        }
        val.assign(card + vs + 1, ve - vs - 1);
        while (!val.empty() && val.back() == ' ') val.pop_back();
    } else {
        // Numeric / logical: strip inline comment after '/'
        int ve = vs;
        while (ve < 80 && card[ve] != '/') ++ve;
        val.assign(card + vs, ve - vs);
        while (!val.empty() && val.back() == ' ') val.pop_back();
    }
    return true;
}

static Header readHeader(const std::string &path) {
    Header h;
    std::ifstream f(path, std::ios::binary);
    if (!f) return h;

    char card[80];
    size_t bytesRead = 0;
    int naxis = 0;

    while (f.read(card, 80)) {
        bytesRead += 80;
        std::string key, val;
        if (!parseCard(card, key, val)) break; // END
        if (val.empty()) continue;
        h.keywords[key] = val;
        try {
            // Replace Fortran-style 'D' exponent with 'E' for stod
            auto fixD = [](std::string s) {
                for (char &c : s) if (c == 'D' || c == 'd') c = 'E';
                return s;
            };
            if      (key == "BITPIX") h.bitpix   = std::stoi(val);
            else if (key == "NAXIS")  naxis       = std::stoi(val);
            else if (key == "NAXIS1") h.width     = std::stoll(val);
            else if (key == "NAXIS2") h.height    = std::stoll(val);
            else if (key == "NAXIS3") h.channels  = std::stoll(val);
            else if (key == "BSCALE") h.bscale    = std::stod(fixD(val));
            else if (key == "BZERO")  h.bzero     = std::stod(fixD(val));
        } catch (...) {}
    }

    if (naxis < 2 || h.width <= 0 || h.height <= 0) return h;
    if (naxis < 3) h.channels = 1;

    // Data block begins at the next 2880-byte boundary after the header
    h.dataOffset = ((bytesRead + 2879) / 2880) * 2880;
    h.valid = true;
    return h;
}

// Read pixel data as planar float, normalised per-channel to [0,1].
// FITS stores pixels big-endian; multi-channel data is channel-major (planar).
static std::vector<float> readPixels(const std::string &path, const Header &h) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return {};
    f.seekg((std::streamoff)h.dataOffset);

    int64_t ppc   = h.width * h.height;
    int64_t total = ppc * h.channels;
    int     eb    = std::abs(h.bitpix) / 8; // bytes per element

    std::vector<uint8_t> raw((size_t)(total * eb));
    if (!f.read(reinterpret_cast<char *>(raw.data()), (std::streamsize)raw.size()))
        return {};

    std::vector<float> px(total);
    double bs = h.bscale, bz = h.bzero;

    for (int64_t i = 0; i < total; i++) {
        const uint8_t *p = raw.data() + i * eb;
        double v = 0.0;
        switch (h.bitpix) {
            case   8: v = p[0]; break;
            case  16: { int16_t  iv; uint16_t uv = ((uint16_t)p[0]<<8)|p[1];
                        memcpy(&iv, &uv, 2); v = iv; break; }
            case  32: { int32_t  iv; uint32_t uv = ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
                        memcpy(&iv, &uv, 4); v = iv; break; }
            case  64: { int64_t iv = 0;
                        for (int b = 0; b < 8; b++) iv = (iv << 8) | p[b];
                        v = (double)iv; break; }
            case -32: { uint32_t bits = ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
                        float fv; memcpy(&fv, &bits, 4); v = fv; break; }
            case -64: { uint64_t bits = 0;
                        for (int b = 0; b < 8; b++) bits = (bits << 8) | p[b];
                        memcpy(&v, &bits, 8); break; }
        }
        px[i] = (float)(bs * v + bz);
    }

    // Normalise each channel to [0,1] so STF works correctly
    for (int64_t c = 0; c < h.channels; c++) {
        float *ch = px.data() + c * ppc;
        float mn = *std::min_element(ch, ch + ppc);
        float mx = *std::max_element(ch, ch + ppc);
        float range = mx - mn;
        if (range < 1e-10f) continue;
        for (int64_t i = 0; i < ppc; i++)
            ch[i] = (ch[i] - mn) / range;
    }

    return px;
}

static NSImage *decodeImage(const std::string &path, const Header &h, bool applyStretch,
                            CGSize scaleMax = {0, 0}) {
    auto px = readPixels(path, h);
    if (px.empty()) return nil;

    uint64_t ch  = (uint64_t)std::min(h.channels, (int64_t)3);
    int64_t  ppc = h.width * h.height;
    std::vector<STFParams> params(ch);
    if (applyStretch)
        for (uint64_t c = 0; c < ch; c++)
            params[c] = computeSTF(px.data() + c * ppc, (size_t)ppc);
    else
        for (uint64_t c = 0; c < ch; c++)
            params[c] = {0.0f, 0.5f};

    NSImage *img = buildNSImage((uint64_t)h.width, (uint64_t)h.height, ch, px, params);
    if (!img) return nil;
    return (scaleMax.width > 0) ? scaleToFit(img, scaleMax) : img;
}

} // namespace fits

// ─────────────────────────────────────────────────────────────
// ObjC bridge
// ─────────────────────────────────────────────────────────────

static bool isFITS(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    return [ext isEqualToString:@"fits"] ||
           [ext isEqualToString:@"fit"]  ||
           [ext isEqualToString:@"fts"];
}

@implementation XISFBridge

+ (nullable NSImage *)thumbnailImageForURL:(NSURL *)url
                                   maxSize:(CGSize)maxSize
                                     error:(NSError **)error {
    const char *path = url.fileSystemRepresentation;
    if (!path) {
        if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid file URL"}];
        return nil;
    }

    if (isFITS(url)) {
        fits::Header h = fits::readHeader(path);
        if (!h.valid) {
            if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:4
                                 userInfo:@{NSLocalizedDescriptionKey: @"Could not parse FITS header"}];
            return nil;
        }
        return fits::decodeImage(path, h, /*applyStretch=*/true, maxSize);
    }

    try {
        LibXISF::XISFReader reader;
        reader.open(std::filesystem::path(path));

        LibXISF::Image thumb = reader.getThumbnail();
        if (thumb.width() > 0 && thumb.height() > 0 && thumb.imageData() != nullptr) {
            NSImage *img = decodeXISFImage(thumb, /*applyStretch=*/false);
            return img ? scaleToFit(img, maxSize) : nil;
        }

        if (reader.imagesCount() == 0) {
            if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"XISF file contains no images"}];
            return nil;
        }
        LibXISF::Image img = reader.getImage(0, /*readPixels=*/true);
        NSImage *result = decodeXISFImage(img, /*applyStretch=*/true);
        return result ? scaleToFit(result, maxSize) : nil;

    } catch (const std::exception &e) {
        if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
    }
    return nil;
}

+ (nullable NSImage *)previewImageForURL:(NSURL *)url
                                   error:(NSError **)error {
    const char *path = url.fileSystemRepresentation;
    if (!path) {
        if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid file URL"}];
        return nil;
    }

    if (isFITS(url)) {
        fits::Header h = fits::readHeader(path);
        if (!h.valid) {
            if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:4
                                 userInfo:@{NSLocalizedDescriptionKey: @"Could not parse FITS header"}];
            return nil;
        }
        return fits::decodeImage(path, h, /*applyStretch=*/true);
    }

    try {
        LibXISF::XISFReader reader;
        reader.open(std::filesystem::path(path));
        if (reader.imagesCount() == 0) {
            if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"XISF file contains no images"}];
            return nil;
        }
        LibXISF::Image img = reader.getImage(0, /*readPixels=*/true);
        return decodeXISFImage(img, /*applyStretch=*/true);

    } catch (const std::exception &e) {
        if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
    }
    return nil;
}

+ (nullable NSDictionary<NSString *, NSString *> *)metadataForURL:(NSURL *)url
                                                            error:(NSError **)error {
    const char *path = url.fileSystemRepresentation;
    if (!path) {
        if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid file URL"}];
        return nil;
    }

    if (isFITS(url)) {
        fits::Header h = fits::readHeader(path);
        if (!h.valid) return @{};
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (const auto &kv : h.keywords) {
            NSString *key = @(kv.first.c_str());
            NSString *val = @(kv.second.c_str());
            if (val.length > 0) dict[key] = val;
        }
        dict[@"__WIDTH__"]  = [NSString stringWithFormat:@"%lld", h.width];
        dict[@"__HEIGHT__"] = [NSString stringWithFormat:@"%lld", h.height];
        return [dict copy];
    }

    try {
        LibXISF::XISFReader reader;
        reader.open(std::filesystem::path(path));
        if (reader.imagesCount() == 0) return @{};

        const LibXISF::Image &img = reader.getImage(0, /*readPixels=*/false);
        NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];

        for (const auto &kw : img.fitsKeywords()) {
            if (kw.name.empty() || kw.value.empty()) continue;
            NSString *key = @(kw.name.c_str());
            NSString *val = [@(kw.value.c_str())
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"' \t"]];
            if (val.length > 0) dict[key] = val;
        }

        struct Mapping { const char *xisfId; const char *fitsKey; };
        static const Mapping kMap[] = {
            {"Instrument:Camera:Gain",          "GAIN"},
            {"Instrument:Sensor:Temperature",   "CCD-TEMP"},
            {"Instrument:Filter:Name",          "FILTER"},
            {"Instrument:FrameExposureTime",    "EXPTIME"},
            {"Observation:Object:Name",         "OBJECT"},
            {"Observation:Time:Start",          "DATE-OBS"},
            {"Instrument:Camera:Name",          "INSTRUME"},
            {"Instrument:Telescope:Name",       "TELESCOP"},
            {"Instrument:Telescope:FocalLength","FOCALLEN"},
        };
        for (const auto &prop : img.imageProperties()) {
            for (const auto &m : kMap) {
                if (prop.id != m.xisfId) continue;
                NSString *fitsKey = @(m.fitsKey);
                if (dict[fitsKey] != nil) break;
                std::string sv = prop.value.toString();
                NSString *val = [@(sv.c_str())
                    stringByTrimmingCharactersInSet:
                        [NSCharacterSet characterSetWithCharactersInString:@"' \t"]];
                if (val.length > 0) dict[fitsKey] = val;
                break;
            }
        }

        dict[@"__WIDTH__"]  = [NSString stringWithFormat:@"%llu", img.width()];
        dict[@"__HEIGHT__"] = [NSString stringWithFormat:@"%llu", img.height()];
        return [dict copy];

    } catch (const std::exception &e) {
        if (error) *error = [NSError errorWithDomain:@"XISFBridge" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
    }
    return nil;
}

@end
