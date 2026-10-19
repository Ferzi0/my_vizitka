// Вырезка портрета для первого экрана: Apple Vision (локально, без сети) + доводка маски + ч/б тонирование.
// Собирается и запускается из tools/portrait.sh (clang из Xcode Command Line Tools, macOS 14+).
// Swift здесь не используется намеренно: на машине разработки Swift-компилятор не совпадал с SDK
// и не собирал даже Foundation; Objective-C собирается тем же clang без зависимостей.
//
//   cutout master <фото> <master.png> [--debug ПАПКА]
//       Маска человека (VNGeneratePersonInstanceMaskRequest, полное разрешение), ограниченная маской
//       переднего плана (VNGenerateForegroundInstanceMaskRequest, +3 px); если человека не нашлось —
//       только передний план. Затем:
//         · остаётся только самый крупный объект (мусор маски убирается), мелкие дыры заливаются;
//         · край поджимается и сглаживается (кривая по альфе ≈ сужение на 0,5–1,5 px + перо ~1 px);
//         · «ореол» старого фона убирается (decontaminate): цвет краевых пикселей пересчитывается
//           из смеси «объект/фон» и из ближайшей внутренней области;
//         · перевод в серый, кривая контраста (чёрное не в 0, светлое не выгорает).
//       Результат — серый с альфа-каналом в полном разрешении, без метаданных (EXIF/GPS не переносятся).
//
//   cutout crop <master.png> <out.png> --width W --aspect W/H --bottom ДОЛЯ [--head ДОЛЯ] [--cx ДОЛЯ] [--sharpen S] [--levels N]
//       Кадр: низ — на высоте ДОЛЯ от высоты фото (линия пояса/груди), верх — макушка + запас --head
//       (доля высоты кадра), ширина — по пропорции, по центру человека (или --cx — доля ширины фото).
//       Уменьшение с премультиплицированной альфой, затем лёгкая резкость (unsharp) по яркости.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <CoreVideo/CoreVideo.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>

static void fail(NSString *msg) { fprintf(stderr, "cutout: %s\n", msg.UTF8String); exit(1); }
static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }
static float smooth(float e0, float e1, float x) { float t = clampf((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t); }

// ---------- размытие: 3 прохода скользящего среднего ≈ гаусс, время не зависит от радиуса ----------
static void boxH(const float *src, float *dst, int w, int h, int r) {
  float inv = 1.f / (2 * r + 1);
  for (int y = 0; y < h; y++) {
    const float *s = src + (size_t)y * w; float *d = dst + (size_t)y * w;
    double acc = 0;
    for (int i = -r; i <= r; i++) acc += s[i < 0 ? 0 : i >= w ? w - 1 : i];
    for (int x = 0; x < w; x++) {
      d[x] = (float)(acc * inv);
      int add = x + r + 1, sub = x - r;
      acc += s[add >= w ? w - 1 : add] - s[sub < 0 ? 0 : sub];
    }
  }
}
static void boxV(const float *src, float *dst, int w, int h, int r) {
  float inv = 1.f / (2 * r + 1);
  double *acc = calloc(w, sizeof(double));
  for (int x = 0; x < w; x++) for (int i = -r; i <= r; i++) acc[x] += src[(size_t)(i < 0 ? 0 : i >= h ? h - 1 : i) * w + x];
  for (int y = 0; y < h; y++) {
    int add = y + r + 1, sub = y - r;
    const float *sa = src + (size_t)(add >= h ? h - 1 : add) * w, *ss = src + (size_t)(sub < 0 ? 0 : sub) * w;
    float *d = dst + (size_t)y * w;
    for (int x = 0; x < w; x++) { d[x] = (float)(acc[x] * inv); acc[x] += sa[x] - ss[x]; }
  }
  free(acc);
}
static void blur(float *img, int w, int h, int r) {
  if (r < 1) return;
  float *tmp = malloc(sizeof(float) * (size_t)w * h);
  for (int p = 0; p < 3; p++) { boxH(img, tmp, w, h, r); boxV(tmp, img, w, h, r); }
  free(tmp);
}
static float *fdup(const float *a, size_t n) { float *b = malloc(sizeof(float) * n); memcpy(b, a, sizeof(float) * n); return b; }

// ---------- ввод/вывод ----------
static CGImageRef loadImage(NSString *path) {
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (!src || CGImageSourceGetCount(src) < 1) fail([NSString stringWithFormat:@"не читается файл %@", path]);
  NSDictionary *p = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
  int maxSide = MAX([p[@"PixelWidth"] intValue], [p[@"PixelHeight"] intValue]);
  // миниатюра в полный размер с учётом поворота из EXIF (Orientation)
  NSDictionary *opt = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                         (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                         (id)kCGImageSourceThumbnailMaxPixelSize: @(maxSide) };
  CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
  CFRelease(src);
  if (!img) fail(@"не удалось декодировать фото");
  return img;
}
// серый + альфа (не премультиплицированные, 0…1) → PNG (8 бит, серый с альфой, без метаданных)
static void savePNG(NSString *path, const float *L, const float *A, int w, int h) {
  uint8_t *buf = malloc((size_t)w * h * 2);
  for (size_t i = 0; i < (size_t)w * h; i++) {
    float a = clampf(A[i], 0, 1), l = clampf(L[i], 0, 1);
    buf[i * 2] = (uint8_t)lrintf(l * a * 255.f);   // премультиплицированно — так хранит CGBitmapContext
    buf[i * 2 + 1] = (uint8_t)lrintf(a * 255.f);
  }
  CGColorSpaceRef gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
  CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, (size_t)w * 2, gray, kCGImageAlphaPremultipliedLast);
  if (!c) fail(@"CGBitmapContext (серый + альфа) не создан");
  CGImageRef im = CGBitmapContextCreateImage(c);
  CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
  if (!d) fail([NSString stringWithFormat:@"не записать %@", path]);
  CGImageDestinationAddImage(d, im, NULL);
  if (!CGImageDestinationFinalize(d)) fail([NSString stringWithFormat:@"не записать %@", path]);
  CFRelease(d); CGImageRelease(im); CGContextRelease(c); CGColorSpaceRelease(gray); free(buf);
  // ImageIO дописывает eXIf и профиль iCCP — убираем всё, кроме обязательных блоков (IHDR, IDAT, IEND):
  // в файле на сайте не должно быть метаданных; без профиля серый читается как sRGB, как AVIF/WebP.
  NSData *png = [NSData dataWithContentsOfFile:path];
  const uint8_t *b = png.bytes; NSUInteger len = png.length, i = 8;
  NSMutableData *clean = [NSMutableData dataWithBytes:b length:8];
  while (i + 12 <= len) {
    uint32_t n = (uint32_t)b[i] << 24 | (uint32_t)b[i + 1] << 16 | (uint32_t)b[i + 2] << 8 | b[i + 3];
    if (i + 12 + (NSUInteger)n > len) fail(@"повреждённый PNG при очистке метаданных");
    if (!memcmp(b + i + 4, "IHDR", 4) || !memcmp(b + i + 4, "IDAT", 4) || !memcmp(b + i + 4, "IEND", 4) || !memcmp(b + i + 4, "tRNS", 4))
      [clean appendBytes:b + i length:12 + n];
    i += 12 + n;
  }
  if (![clean writeToFile:path atomically:YES]) fail([NSString stringWithFormat:@"не записать %@", path]);
}
static void saveGray(NSString *path, const float *M, int w, int h) {
  float *one = malloc(sizeof(float) * (size_t)w * h);
  for (size_t i = 0; i < (size_t)w * h; i++) one[i] = 1;
  savePNG(path, M, one, w, h); free(one);
}
// PNG/любое изображение → серый (L) и альфа (A), не премультиплицированные
static void readGrayAlpha(CGImageRef img, float **L, float **A, int *W, int *H) {
  int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
  CGColorSpaceRef gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
  uint8_t *buf = calloc((size_t)w * h * 2, 1);
  CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, (size_t)w * 2, gray, kCGImageAlphaPremultipliedLast);
  CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
  *L = malloc(sizeof(float) * (size_t)w * h); *A = malloc(sizeof(float) * (size_t)w * h);
  for (size_t i = 0; i < (size_t)w * h; i++) {
    float a = buf[i * 2 + 1] / 255.f;
    (*A)[i] = a; (*L)[i] = a > 0 ? clampf(buf[i * 2] / 255.f / a, 0, 1) : 0;
  }
  CGContextRelease(c); CGColorSpaceRelease(gray); free(buf);
  *W = w; *H = h;
}

// ---------- маска Vision ----------
static float *pixelBufferToFloat(CVPixelBufferRef pb, int w, int h) {
  if ((int)CVPixelBufferGetWidth(pb) != w || (int)CVPixelBufferGetHeight(pb) != h) fail(@"маска Vision другого размера");
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  OSType f = CVPixelBufferGetPixelFormatType(pb);
  size_t bpr = CVPixelBufferGetBytesPerRow(pb);
  uint8_t *base = CVPixelBufferGetBaseAddress(pb);
  float *m = malloc(sizeof(float) * (size_t)w * h);
  for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
    float v = f == kCVPixelFormatType_OneComponent32Float ? ((float *)(base + y * bpr))[x] : (base + y * bpr)[x] / 255.f;
    m[(size_t)y * w + x] = clampf(v, 0, 1);
  }
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  return m;
}
// Маска человека: VNGeneratePersonInstanceMaskRequest даёт подробный край (пряди волос), но на размытых
// (вне фокуса) краях и у соседних предметов (скамейка) расплывается полупрозрачным «хвостом».
// VNGenerateForegroundInstanceMaskRequest — плотная и гладкая, без прядей. Итог: маска человека,
// ограниченная маской переднего плана, расширенной на ~3 px (пряди внутри неё сохраняются, хвосты — нет).
static float *instanceMask(VNImageRequestHandler *handler, VNInstanceMaskObservation *o, int w, int h) API_AVAILABLE(macos(14.0)) {
  if (!o || !o.allInstances.count) return NULL;
  NSError *err = nil;
  CVPixelBufferRef pb = [o generateScaledMaskForImageForInstances:o.allInstances fromRequestHandler:handler error:&err];
  return pb ? pixelBufferToFloat(pb, w, h) : NULL;
}
static float *visionMask(CGImageRef img, int w, int h, NSString *debug, NSString **how) API_AVAILABLE(macos(14.0)) {
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
  NSError *err = nil;
  VNGeneratePersonInstanceMaskRequest *person = [VNGeneratePersonInstanceMaskRequest new];
  VNGenerateForegroundInstanceMaskRequest *fg = [VNGenerateForegroundInstanceMaskRequest new];
  if (![handler performRequests:@[person, fg] error:&err]) fail([NSString stringWithFormat:@"Vision: %@", err.localizedDescription]);
  float *P = instanceMask(handler, person.results.firstObject, w, h);
  float *F = instanceMask(handler, fg.results.firstObject, w, h);
  if (debug && P) saveGray([debug stringByAppendingPathComponent:@"1-person.png"], P, w, h);
  if (debug && F) saveGray([debug stringByAppendingPathComponent:@"1-foreground.png"], F, w, h);
  if (!P && !F) fail(@"Vision не нашёл на фото ни человека, ни объекта переднего плана");
  if (!P) { *how = @"передний план (VNGenerateForegroundInstanceMaskRequest) — человек не найден"; return F; }
  if (!F) { *how = @"человек (VNGeneratePersonInstanceMaskRequest), без ограничения передним планом"; return P; }
  size_t n = (size_t)w * h;
  int r = MAX(1, (int)lrintf(MAX(w, h) / 1300.f));      // ≈ 3 px на 4032
  for (size_t i = 0; i < n; i++) F[i] = F[i] > 0.5f ? 1 : 0;
  blur(F, w, h, r);
  for (size_t i = 0; i < n; i++) { float g = clampf(F[i] * 1.8f, 0, 1); if (P[i] > g) P[i] = g; }
  free(F);
  *how = @"человек (VNGeneratePersonInstanceMaskRequest) ∩ передний план (VNGenerateForegroundInstanceMaskRequest, +3 px)";
  return P;
}

// ---------- связные области (4-связность), метки int32 ----------
static int label(const uint8_t *bin, int w, int h, int32_t *lab, int **sizesOut) {
  size_t n = (size_t)w * h; memset(lab, 0, sizeof(int32_t) * n);
  int32_t *stack = malloc(sizeof(int32_t) * n);
  int cap = 64, count = 0; int *sizes = malloc(sizeof(int) * cap);
  for (size_t i = 0; i < n; i++) {
    if (!bin[i] || lab[i]) continue;
    if (count + 1 >= cap) { cap *= 2; sizes = realloc(sizes, sizeof(int) * cap); }
    int id = ++count; sizes[id] = 0;
    size_t sp = 0; stack[sp++] = (int32_t)i; lab[i] = id;
    while (sp) {
      int32_t p = stack[--sp]; sizes[id]++;
      int x = p % w, y = p / w;
      int nb[4] = { x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1 };
      for (int k = 0; k < 4; k++) if (nb[k] >= 0 && bin[nb[k]] && !lab[nb[k]]) { lab[nb[k]] = id; stack[sp++] = nb[k]; }
    }
  }
  free(stack); *sizesOut = sizes; return count;
}

static float percentile(const float *v, const float *A, size_t n, float amin, float q) {
  int hist[1024] = {0}; long tot = 0;
  for (size_t i = 0; i < n; i++) if (A[i] >= amin) { hist[(int)(clampf(v[i], 0, 1) * 1023)]++; tot++; }
  long need = (long)(q * tot), acc = 0;
  for (int b = 0; b < 1024; b++) { acc += hist[b]; if (acc >= need) return b / 1023.f; }
  return 1;
}

static int cmdMaster(NSString *inPath, NSString *outPath, NSString *debug) {
  CGImageRef img = loadImage(inPath);
  int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
  size_t n = (size_t)w * h;
  fprintf(stderr, "фото: %d×%d\n", w, h);

  // 1. Яркость (sRGB-гамма; из Display P3 переводит CoreGraphics). Фото с прозрачностью (уже вырезанное
  //    вручную) кладётся на светло-серый фон: иначе прозрачное стало бы чёрным, и Vision путал бы его
  //    с тёмной одеждой. Этот же «плоский» кадр идёт в Vision.
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  uint8_t *rgba = calloc(n * 4, 1);
  CGContextRef c = CGBitmapContextCreate(rgba, w, h, 8, (size_t)w * 4, srgb, kCGImageAlphaNoneSkipLast);
  CGContextSetRGBFillColor(c, 0.82, 0.82, 0.82, 1);
  CGContextFillRect(c, CGRectMake(0, 0, w, h));
  CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
  CGImageRef flat = CGBitmapContextCreateImage(c);
  CGContextRelease(c);
  CGImageRelease(img);
  img = flat;
  float *L = malloc(sizeof(float) * n);
  for (size_t i = 0; i < n; i++) L[i] = (0.2126f * rgba[i * 4] + 0.7152f * rgba[i * 4 + 1] + 0.0722f * rgba[i * 4 + 2]) / 255.f;
  free(rgba);

  // 2. Маска
  NSString *how = nil;
  float *A = NULL;
  if (@available(macOS 14.0, *)) A = visionMask(img, w, h, debug, &how);
  else fail(@"нужен macOS 14 или новее (маски Vision для человека и переднего плана)");
  fprintf(stderr, "маска: %s\n", how.UTF8String);
  float mx = 0; for (size_t i = 0; i < n; i++) if (A[i] > mx) mx = A[i];
  if (mx < 0.5f) fail(@"маска пустая");
  for (size_t i = 0; i < n; i++) A[i] = clampf(A[i] / mx, 0, 1);

  // 3. Только самый крупный объект: всё, что не касается его (с запасом), — мусор маски
  uint8_t *bin = malloc(n); int32_t *lab = malloc(sizeof(int32_t) * n); int *sizes = NULL;
  for (size_t i = 0; i < n; i++) bin[i] = A[i] > 0.5f;
  int cnt = label(bin, w, h, lab, &sizes), best = 0;
  for (int k = 1; k <= cnt; k++) if (!best || sizes[k] > sizes[best]) best = k;
  float *keep = malloc(sizeof(float) * n);
  for (size_t i = 0; i < n; i++) keep[i] = lab[i] == best ? 1 : 0;
  int pad = MAX(4, (int)lrintf(MAX(w, h) * 0.004f));
  blur(keep, w, h, pad);
  size_t dropped = 0;
  for (size_t i = 0; i < n; i++) if (keep[i] < 0.004f && A[i] > 0) { if (A[i] > 0.5f) dropped++; A[i] = 0; }
  fprintf(stderr, "областей в маске: %d, оставлена самая крупная; убрано пикселей мусора: %zu\n", cnt, dropped);
  free(keep); free(sizes);

  // 4. Мелкие дыры внутри фигуры (< 0,05 % кадра) — залить; крупные (просвет между рукой и телом) — оставить
  for (size_t i = 0; i < n; i++) bin[i] = A[i] <= 0.5f;
  cnt = label(bin, w, h, lab, &sizes);
  uint8_t *border = calloc(cnt + 1, 1);
  for (int x = 0; x < w; x++) { border[lab[x]] = 1; border[lab[(size_t)(h - 1) * w + x]] = 1; }
  for (int y = 0; y < h; y++) { border[lab[(size_t)y * w]] = 1; border[lab[(size_t)y * w + w - 1]] = 1; }
  size_t filled = 0, maxHole = (size_t)(n * 0.0005);
  for (size_t i = 0; i < n; i++) if (lab[i] && !border[lab[i]] && (size_t)sizes[lab[i]] < maxHole) { A[i] = 1; filled++; }
  fprintf(stderr, "залито пикселей в мелких дырах: %zu\n", filled);
  free(border); free(sizes); free(bin); free(lab);

  // 5. Край: кривая по альфе (полупрозрачный «хвост» старого фона срезается — это и есть сужение
  //    на 0,5–1,5 px по мягкому краю), затем перо ~1 px. Пряди волос с альфой > 0,28 сохраняются.
  for (size_t i = 0; i < n; i++) A[i] = smooth(0.28f, 0.92f, A[i]);
  int feather = MAX(1, (int)lrintf(MAX(w, h) / 4032.f));
  blur(A, w, h, feather);
  if (debug) saveGray([debug stringByAppendingPathComponent:@"2-alpha.png"], A, w, h);

  // 6. Decontaminate: в краевом пикселе I = a·F + (1 − a)·B. B — местный фон (размытый фон вокруг),
  //    F_in — цвет ближайшей внутренней области. F = (I − (1 − a)·B) / a, ограничен около F_in;
  //    при малой альфе берётся F_in (там «смесь» ненадёжна).
  float *bw = malloc(sizeof(float) * n), *bs = malloc(sizeof(float) * n);
  float *fw = malloc(sizeof(float) * n), *fs = malloc(sizeof(float) * n);
  float *fw2 = malloc(sizeof(float) * n), *fs2 = malloc(sizeof(float) * n);
  for (size_t i = 0; i < n; i++) {
    float b = A[i] < 0.02f ? 1 : 0, f = A[i] > 0.97f ? 1 : 0;
    bw[i] = b; bs[i] = b * L[i]; fw[i] = fw2[i] = f; fs[i] = fs2[i] = f * L[i];
  }
  int rb = MAX(8, (int)lrintf(MAX(w, h) * 0.012f)), rf = MAX(2, (int)lrintf(MAX(w, h) * 0.0015f)), rf2 = MAX(8, (int)lrintf(MAX(w, h) * 0.01f));
  blur(bw, w, h, rb); blur(bs, w, h, rb);
  blur(fw, w, h, rf); blur(fs, w, h, rf);
  blur(fw2, w, h, rf2); blur(fs2, w, h, rf2);
  size_t fixed = 0;
  for (size_t i = 0; i < n; i++) {
    float a = A[i];
    if (a >= 0.97f || a <= 0.002f) continue;
    float fin = fw[i] > 0.02f ? fs[i] / fw[i] : fw2[i] > 1e-4f ? fs2[i] / fw2[i] : L[i];
    float bg = bw[i] > 1e-3f ? bs[i] / bw[i] : fin;
    float un = clampf((L[i] - (1 - a) * bg) / MAX(a, 0.05f), MAX(0, fin - 0.22f), MIN(1, fin + 0.22f));
    float t = smooth(0.35f, 0.9f, a);
    L[i] = un * t + fin * (1 - t);
    fixed++;
  }
  fprintf(stderr, "краевых пикселей пересчитано: %zu\n", fixed);
  free(bw); free(bs); free(fw); free(fs); free(fw2); free(fs2);

  // 7. Тон: уровни по самой фигуре (0,3…99,7 перцентиль → 0,045…0,94: тени не проваливаются в 0,
  //    светлая толстовка не выгорает), мягкая S-кривая и чуть приподнятые средние тона (лицо, глаза).
  float lo = percentile(L, A, n, 0.9f, 0.003f), hi = percentile(L, A, n, 0.9f, 0.997f);
  fprintf(stderr, "уровни фигуры: %.3f…%.3f\n", lo, hi);
  for (size_t i = 0; i < n; i++) {
    if (A[i] <= 0) { L[i] = 0; continue; }
    float t = clampf((L[i] - lo) / MAX(hi - lo, 0.05f), 0, 1);
    t = powf(t, 0.94f);                         // средние тона чуть светлее
    t = t + 0.22f * (t * t * (3 - 2 * t) - t);  // мягкая S-кривая (+контраст в средних)
    L[i] = 0.045f + t * (0.94f - 0.045f);
  }

  savePNG(outPath, L, A, w, h);
  // габариты фигуры (для подбора кадров)
  int top = h, bottom = 0, left = w, right = 0;
  for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) if (A[(size_t)y * w + x] > 0.5f) {
    if (y < top) top = y; if (y > bottom) bottom = y; if (x < left) left = x; if (x > right) right = x;
  }
  printf("master %s %dx%d figure x %d..%d y %d..%d\n", outPath.lastPathComponent.UTF8String, w, h, left, right, top, bottom);
  free(L); free(A); CGImageRelease(img); CGColorSpaceRelease(srgb);
  return 0;
}

static int cmdCrop(NSString *inPath, NSString *outPath, NSDictionary *o) {
  int outW = [o[@"width"] intValue];
  float aspect = [o[@"aspect"] floatValue], bottomF = [o[@"bottom"] floatValue];
  float head = o[@"head"] ? [o[@"head"] floatValue] : 0.06f, sharpen = o[@"sharpen"] ? [o[@"sharpen"] floatValue] : 0.35f;
  if (outW < 16 || aspect <= 0 || bottomF <= 0 || bottomF > 1) fail(@"crop: нужны --width, --aspect, --bottom (0…1)");
  CGImageRef img = loadImage(inPath);
  float *L, *A; int w, h;
  readGrayAlpha(img, &L, &A, &w, &h);
  int bottom = (int)lrintf(bottomF * h);
  int top = -1;
  for (int y = 0; y < h && top < 0; y++) { int k = 0; for (int x = 0; x < w; x++) if (A[(size_t)y * w + x] > 0.5f) k++; if (k > w / 400 + 2) top = y; }
  if (top < 0 || top >= bottom) fail(@"crop: фигура не найдена выше линии --bottom");
  float cropH = (bottom - top) / (1 - head), cropW = cropH * aspect;
  // центр: --cx или центр масс фигуры между макушкой и линией обреза
  double sx = 0, sw = 0;
  for (int y = top; y < bottom; y++) for (int x = 0; x < w; x++) { float a = A[(size_t)y * w + x]; sx += a * x; sw += a; }
  float cx = o[@"cx"] ? [o[@"cx"] floatValue] * w : (float)(sx / MAX(sw, 1));
  float x0 = cx - cropW / 2, y0 = bottom - cropH;   // y0 вверх от низа кадра в координатах фото (сверху вниз)
  int outH = (int)lrintf(outW / aspect);
  // уменьшение: рисуем исходник (премультиплицированный) в контекст нужного размера
  CGColorSpaceRef gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
  uint8_t *buf = calloc((size_t)outW * outH * 2, 1);
  CGContextRef c = CGBitmapContextCreate(buf, outW, outH, 8, (size_t)outW * 2, gray, kCGImageAlphaPremultipliedLast);
  CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
  float s = outW / cropW;
  // CG: начало координат внизу слева
  CGContextDrawImage(c, CGRectMake(-x0 * s, -(h - bottom) * s, w * s, h * s), img);
  CGContextRelease(c);
  size_t m = (size_t)outW * outH;
  float *l = malloc(sizeof(float) * m), *a = malloc(sizeof(float) * m);
  for (size_t i = 0; i < m; i++) { a[i] = buf[i * 2 + 1] / 255.f; l[i] = a[i] > 0 ? clampf(buf[i * 2] / 255.f / a[i], 0, 1) : 0; }
  // резкость: unsharp по яркости (радиус ~1 px), размытая яркость — с учётом альфы
  float *pb = malloc(sizeof(float) * m), *ab = fdup(a, m);
  for (size_t i = 0; i < m; i++) pb[i] = l[i] * a[i];
  blur(pb, outW, outH, 1); blur(ab, outW, outH, 1);
  for (size_t i = 0; i < m; i++) if (a[i] > 0 && ab[i] > 1e-3f) {
    float lb = pb[i] / ab[i];
    l[i] = clampf(l[i] + sharpen * (l[i] - lb), 0.03f, 0.96f);
  }
  // --levels N: только для запасного PNG — серый округляется до N уровней (меньше файл; на вид почти без разницы),
  // альфа внутри фигуры — сплошная 1, край — до 32 уровней
  int levels = o[@"levels"] ? [o[@"levels"] intValue] : 0;
  if (levels >= 2) for (size_t i = 0; i < m; i++) {
    l[i] = roundf(l[i] * (levels - 1)) / (levels - 1);
    a[i] = a[i] > 0.985f ? 1 : a[i] < 0.015f ? 0 : roundf(a[i] * 31) / 31;
  }
  savePNG(outPath, l, a, outW, outH);
  printf("crop %s %dx%d (из фото: x %.0f, y %.0f, %.0f×%.0f; макушка %d, низ %d)\n", outPath.lastPathComponent.UTF8String, outW, outH, x0, y0, cropW, cropH, top, bottom);
  free(l); free(a); free(pb); free(ab); free(buf); free(L); free(A); CGColorSpaceRelease(gray); CGImageRelease(img);
  return 0;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc >= 4 && !strcmp(argv[1], "master")) {
      NSString *debug = nil;
      for (int i = 4; i + 1 < argc; i++) if (!strcmp(argv[i], "--debug")) debug = @(argv[i + 1]);
      return cmdMaster(@(argv[2]), @(argv[3]), debug);
    }
    if (argc >= 4 && !strcmp(argv[1], "crop")) {
      NSMutableDictionary *o = [NSMutableDictionary dictionary];
      for (int i = 4; i + 1 < argc; i += 2) {
        if (strncmp(argv[i], "--", 2)) fail([NSString stringWithFormat:@"непонятный параметр %s", argv[i]]);
        o[@(argv[i] + 2)] = @(atof(argv[i + 1]));
      }
      return cmdCrop(@(argv[2]), @(argv[3]), o);
    }
    fprintf(stderr, "использование:\n  cutout master <фото> <master.png> [--debug ПАПКА]\n"
                    "  cutout crop <master.png> <out.png> --width W --aspect W/H --bottom ДОЛЯ [--head ДОЛЯ] [--cx ДОЛЯ] [--sharpen S]\n");
    return 2;
  }
}
