{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwcaptcha
  ------------------------------------------------------------------
  图形验证码 —— TLWCaptcha（可视控件）+ 服务端 PNG 生成 + 校验表。

  为什么自己做 PNG 而不是用 LCL 的 TBitmap/Canvas：
    · 服务端跑 nogui widgetset，没有真实 Canvas；TBitmap.Canvas 在 nogui 下
      画不出字（更没有字体后端）。
    · 验证码要的只是"几个扭曲的字符 + 干扰线"，用内置 5x7 点阵字模 +
      FPImage 直接写像素，零字体依赖、零 widgetset 依赖，任何档位都能出图。

  数据流（三端各一段）：
    1. 设计期：把 TLWCaptcha 拖到 TLWLoginForm 上（就像拖 TImage）；
       服务端序列化时给出 src = /lw/api/captcha?k=<令牌>&v=<版本>&n&w&h；
    2. 浏览器：<img> 拉这张图。服务端第一次收到该令牌的请求时随机生成
       一个码并记进表里，之后同一令牌直接复用同一个码（页签重绘、
       补丁重建 img 都不会"偷偷换码"，用户输入不会白费）；
    3. 点图片刷新：浏览器只在 URL 上追加 &r=<时间戳>（纯前端，不走事件、
       不占会话执行锁），服务端看到 r 就重新生成码 —— 一张图一个码。
    4. 提交登录：TLWLoginForm 拿输入框文本跟表里的码比（不区分大小写），
       比完即作废（防同一码被暴力重试）；失败时 Refresh 把版本号 +1，
       前端 src 随之变化 -> 自动换一张新图。

  令牌表是"令牌 -> 答案"的进程级表（含锁），不挂在会话对象上：
  验证码图片请求由独立的 HTTP 线程处理，它拿不到正在执行事件的会话，
  用一张带锁的小表最简单，也天然支持多标签页 / 多会话并存。
}
unit lwcaptcha;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, SyncObjs;

type
  { 图形验证码控件。放在登录窗体上即可，尺寸就是图片尺寸。
    浏览器端点一下换一张；业务代码也可以在别处调用 Refresh 主动刷新。 }
  TLWCaptcha = class(TGraphicControl)
  private
    FToken: string;
    FLength: Integer;
    FVersion: Integer;
  protected
    { 设计期占位画法：IDE 里能看见"这是一张验证码"，不至于拖上去一片空白 }
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    { 换一张：作废当前答案，版本号 +1。
      版本号是给浏览器看的 —— 它出现在 src 里，变了浏览器才会重新拉图 }
    procedure Refresh;
    { 当前令牌（第一次访问时才生成，保证没被序列化过的控件不占资源） }
    function Token: string;
    { 序列化用的版本号 }
    property Version: Integer read FVersion;
  published
    { 字符个数，2..8，默认 4 }
    property CaptchaLength: Integer read FLength write FLength default 4;
    property OnClick;
  end;

{ 生成/取回某令牌对应的答案（AForce = True 时强制重生成），并画出 PNG。
   APng 由调用方创建与释放，返回时 Position = 0。 }
procedure LWCaptchaPng(const AToken: string; ALen, AWidth, AHeight: Integer;
  AForce: Boolean; APng: TMemoryStream);

{ 校验：AInput 与令牌对应的答案比对（忽略大小写与首尾空格）。
  结果无论对错，该令牌的答案都作废 —— 一枚码只允许试一次。 }
function LWCaptchaCheck(const AToken, AInput: string): Boolean;

{ 作废某令牌的答案（不影响令牌本身）。 }
procedure LWCaptchaDrop(const AToken: string);

{ 调试/测试用：读当前令牌的答案（不存在时返回空串）。 }
function LWCaptchaPeek(const AToken: string): string;

implementation

uses
  FPImage, FPWritePNG;

const
  { 去掉肉眼易混的 0/O/1/I/L 之外的字符…… 实际保留 L（它在 5x7 里和 1 差得远），
    去掉了 0 O 1 I 四个 }
  CS_CHARS = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  { 5 列 x 7 行点阵，每个字节低 5 位 = 一行（bit4 是最左列） }
  CS_GLYPHS: array[0..31, 0..6] of Byte = (
    ($0E, $11, $01, $02, $04, $08, $1F),   { 2 }
    ($1F, $02, $04, $02, $01, $11, $0E),   { 3 }
    ($02, $06, $0A, $12, $1F, $02, $02),   { 4 }
    ($1F, $10, $1E, $01, $01, $11, $0E),   { 5 }
    ($06, $08, $10, $1E, $11, $11, $0E),   { 6 }
    ($1F, $01, $02, $04, $08, $08, $08),   { 7 }
    ($0E, $11, $11, $0E, $11, $11, $0E),   { 8 }
    ($0E, $11, $11, $0F, $01, $02, $0C),   { 9 }
    ($0E, $11, $11, $1F, $11, $11, $11),   { A }
    ($1E, $11, $11, $1E, $11, $11, $1E),   { B }
    ($0E, $11, $10, $10, $10, $11, $0E),   { C }
    ($1C, $12, $11, $11, $11, $12, $1C),   { D }
    ($1F, $10, $10, $1E, $10, $10, $1F),   { E }
    ($1F, $10, $10, $1E, $10, $10, $10),   { F }
    ($0E, $11, $10, $17, $11, $11, $0F),   { G }
    ($11, $11, $11, $1F, $11, $11, $11),   { H }
    ($07, $02, $02, $02, $02, $12, $0C),   { J }
    ($11, $12, $14, $18, $14, $12, $11),   { K }
    ($10, $10, $10, $10, $10, $10, $1F),   { L }
    ($11, $1B, $15, $15, $11, $11, $11),   { M }
    ($11, $11, $19, $15, $13, $11, $11),   { N }
    ($1E, $11, $11, $1E, $10, $10, $10),   { P }
    ($0E, $11, $11, $11, $15, $12, $0D),   { Q }
    ($1E, $11, $11, $1E, $14, $12, $11),   { R }
    ($0F, $10, $10, $0E, $01, $01, $1E),   { S }
    ($1F, $04, $04, $04, $04, $04, $04),   { T }
    ($11, $11, $11, $11, $11, $11, $0E),   { U }
    ($11, $11, $11, $11, $11, $0A, $04),   { V }
    ($11, $11, $11, $15, $15, $1B, $11),   { W }
    ($11, $11, $0A, $04, $0A, $11, $11),   { X }
    ($11, $11, $0A, $04, $04, $04, $04),   { Y }
    ($1F, $01, $02, $04, $08, $10, $1F)    { Z }
  );

var
  GCaptchaLock: TCriticalSection;
  GCaptchaCodes: TStringList;    { 令牌 = 答案 }
  GCaptchaSeq: Integer;

function Col(r, g, b: Byte): TFPColor; inline;
begin
  Result.Red := r * 257;
  Result.Green := g * 257;
  Result.Blue := b * 257;
  Result.Alpha := alphaOpaque;
end;

procedure PutPx(Img: TFPMemoryImage; x, y: Integer; const C: TFPColor); inline;
begin
  if (x < 0) or (y < 0) or (x >= Img.Width) or (y >= Img.Height) then Exit;
  Img.Colors[x, y] := C;
end;

procedure FillBox(Img: TFPMemoryImage; x, y, w, h: Integer; const C: TFPColor);
var
  i, j: Integer;
begin
  for j := y to y + h - 1 do
    for i := x to x + w - 1 do
      PutPx(Img, i, j, C);
end;

procedure DrawLine(Img: TFPMemoryImage; x0, y0, x1, y1: Integer; const C: TFPColor);
var
  dx, dy, sx, sy, err, e2: Integer;
begin
  dx := Abs(x1 - x0);
  dy := Abs(y1 - y0);
  if x0 < x1 then sx := 1 else sx := -1;
  if y0 < y1 then sy := 1 else sy := -1;
  err := dx - dy;
  repeat
    PutPx(Img, x0, y0, C);
    if (x0 = x1) and (y0 = y1) then Break;
    e2 := 2 * err;
    if e2 > -dy then
    begin
      Inc(err, -dy);
      Inc(x0, sx);
    end;
    if e2 < dx then
    begin
      Inc(err, dx);
      Inc(y0, sy);
    end;
  until False;
end;

function NewToken: string;
begin
  GCaptchaLock.Enter;
  try
    Inc(GCaptchaSeq);
    Result := IntToHex(GCaptchaSeq, 4) + IntToHex(Random(MaxInt), 8);
  finally
    GCaptchaLock.Leave;
  end;
end;

{ 表无限增长会吃内存：超过上限时按插入顺序丢最老的一批。
  验证码是短命数据（几分钟内必被用掉或过期），丢掉不影响正确性。 }
procedure TrimCodes;
begin
  while GCaptchaCodes.Count > 4000 do
    GCaptchaCodes.Delete(0);
end;

procedure LWCaptchaDrop(const AToken: string);
var
  i: Integer;
begin
  if AToken = '' then Exit;
  GCaptchaLock.Enter;
  try
    i := GCaptchaCodes.IndexOfName(AToken);
    if i >= 0 then GCaptchaCodes.Delete(i);
  finally
    GCaptchaLock.Leave;
  end;
end;

function LWCaptchaPeek(const AToken: string): string;
begin
  Result := '';
  if AToken = '' then Exit;
  GCaptchaLock.Enter;
  try
    Result := GCaptchaCodes.Values[AToken];
  finally
    GCaptchaLock.Leave;
  end;
end;

function LWCaptchaCheck(const AToken, AInput: string): Boolean;
var
  code, s: string;
begin
  Result := False;
  if (AToken = '') or (AInput = '') then
  begin
    LWCaptchaDrop(AToken);
    Exit;
  end;
  code := '';
  s := UpperCase(Trim(AInput));
  GCaptchaLock.Enter;
  try
    code := GCaptchaCodes.Values[AToken];
    { 一枚码只试一次：无论对错都立刻作废，避免对同一张图暴力枚举 }
    if code <> '' then
    begin
      Result := SameText(code, s);
      GCaptchaCodes.Delete(GCaptchaCodes.IndexOfName(AToken));
    end;
  finally
    GCaptchaLock.Leave;
  end;
end;

{ ---------------- 出图 ---------------- }

procedure LWCaptchaPng(const AToken: string; ALen, AWidth, AHeight: Integer;
  AForce: Boolean; APng: TMemoryStream);
var
  Img: TFPMemoryImage;
  W, H, n, i, j, ci, cw, scale, gx, gy, x, y, off, rowBit, idx: Integer;
  code: string;
  ch: Char;
  shear: Double;
  fg: TFPColor;
  wr: TFPWriterPNG;
begin
  n := ALen;
  if n < 2 then n := 2;
  if n > 8 then n := 8;
  W := AWidth;
  if W < 48 then W := 48;
  if W > 480 then W := 480;
  H := AHeight;
  if H < 20 then H := 20;
  if H > 160 then H := 160;

  code := '';
  GCaptchaLock.Enter;
  try
    if not AForce then
      code := GCaptchaCodes.Values[AToken];
    if code = '' then
    begin
      code := '';
      for i := 1 to n do
        code := code + CS_CHARS[1 + Random(Length(CS_CHARS))];
      if AToken <> '' then
      begin
        GCaptchaCodes.Values[AToken] := code;
        TrimCodes;
      end;
    end;
  finally
    GCaptchaLock.Leave;
  end;

  { 排障开关：设了环境变量 LW_CAPTCHA_DEBUG 就把令牌与答案打到 stderr。
    正常部署不会设它；自动化测试/远程协助时靠它快速判断"到底是码不对
    还是图不对"，也省得为了看一眼答案临时改代码。 }
  if GetEnvironmentVariable('LW_CAPTCHA_DEBUG') <> '' then
  begin
    WriteLn(StdErr, '[lw] captcha ', AToken, ' = ', code);
    { stderr 重定向到文件时是带缓冲的，服务端着不退出就永远看不到 ——
      排障输出必须立刻可见，否则等于没打 }
    Flush(StdErr);
  end;

  Img := TFPMemoryImage.Create(W, H);
  try    { 背景：极浅的冷灰蓝，与亮色主题的窗口底色接近 }
    FillBox(Img, 0, 0, W, H, Col(246, 249, 253));

    { 背景噪点：浅色小块，制造"纸面颗粒" }
    for i := 1 to 90 do
      PutPx(Img, Random(W), Random(H), Col(226, 232, 241));

    { 干扰线：一条跨越整宽的浅色折线（两条会明显压住字符，小尺寸下
      本来就只有 3~4px 一个字，得不偿失） }
    begin
      y := 4 + Random(H - 8);
      x := 0;
      while x < W do
      begin
        j := x + 6 + Random(10);
        if j > W then j := W;
        DrawLine(Img, x, y, j, 4 + Random(H - 8), Col(206, 216, 230));
        x := j;
        y := 4 + Random(H - 8);
      end;
    end;

    { 字符区：左右各留 6px，字符均分剩余宽度 }
    cw := (W - 12) div n;
    for ci := 0 to n - 1 do
    begin
      ch := code[ci + 1];
      idx := Pos(ch, CS_CHARS) - 1;
      if idx < 0 then idx := 0;

      { 字高占 7 行点阵：尽量顶满可用高度（H-6），点块越大越不容易认错，
        只有宽度不够时才退而求其次缩小 }
      scale := (H - 6) div 7;
      if scale < 2 then scale := 2;
      if (cw div 6) < scale then scale := cw div 6;
      if scale < 2 then scale := 2;

      gx := 6 + ci * cw + (cw - 5 * scale) div 2 + Random(3) - 1;
      gy := (H - 7 * scale) div 2 + Random(5) - 2;

      { 每个字符随机一个倾斜方向（-0.4..0.4），行之间错位形成斜体观感 }
      shear := (Random(81) - 40) / 100;

      { 颜色偏深、偏冷，保证在浅底上清晰 }
      fg := Col(20 + Random(70), 40 + Random(80), 90 + Random(90));

      for i := 0 to 6 do
      begin
        rowBit := CS_GLYPHS[idx, i];
        off := Round((i - 3) * shear * scale);
        for j := 0 to 4 do
          if (rowBit and (1 shl (4 - j))) <> 0 then
            FillBox(Img, gx + j * scale + off, gy + i * scale, scale, scale, fg);
      end;
    end;

    { 前景细噪点：少量深色像素，打断字符边缘的"整块感"
      （数量刻意压得很低：110x34 这种小图上，噪点一多就变成"糊成一团"） }
    for i := 1 to 16 do
      PutPx(Img, Random(W), Random(H), Col(120, 140, 170));

    { 1px 边框：与控件在浏览器里的底色区分开 }
    for x := 0 to W - 1 do
    begin
      PutPx(Img, x, 0, Col(205, 214, 228));
      PutPx(Img, x, H - 1, Col(205, 214, 228));
    end;
    for y := 0 to H - 1 do
    begin
      PutPx(Img, 0, y, Col(205, 214, 228));
      PutPx(Img, W - 1, y, Col(205, 214, 228));
    end;

    wr := TFPWriterPNG.Create;
    try
      wr.Indexed := False;
      wr.UseAlpha := False;
      wr.WordSized := False;
      APng.Clear;
      Img.SaveToStream(APng, wr);
      APng.Position := 0;
    finally
      wr.Free;
    end;
  finally
    Img.Free;
  end;
end;

{ ---------------- TLWCaptcha ---------------- }

constructor TLWCaptcha.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLength := 4;
  FVersion := 0;
  FToken := '';
  Width := 110;
  Height := 34;
  ControlStyle := ControlStyle + [csOpaque];
end;

function TLWCaptcha.Token: string;
begin
  if FToken = '' then
    FToken := NewToken;
  Result := FToken;
end;

procedure TLWCaptcha.Refresh;
begin
  { 作废旧答案 + 版本号 +1：前者让下一次图片请求必然生成新码，
    后者保证浏览器 src 变了（否则它会拿缓存里的同一张图） }
  LWCaptchaDrop(Token);
  Inc(FVersion);
  if Parent <> nil then
    Parent.Invalidate;
end;

procedure TLWCaptcha.Paint;
var
  i: Integer;
begin
  Canvas.Brush.Color := RGBToColor(246, 249, 253);
  Canvas.FillRect(0, 0, Width, Height);
  Canvas.Pen.Color := RGBToColor(205, 214, 228);
  Canvas.Rectangle(0, 0, Width, Height);
  { 设计期示意：画几道斜线当"字符"，运行时由浏览器显示真正的 PNG }
  Canvas.Pen.Color := RGBToColor(70, 100, 150);
  for i := 0 to 3 do
  begin
    Canvas.MoveTo(10 + i * (Width - 30) div 4, Height div 2 - 7);
    Canvas.LineTo(16 + i * (Width - 30) div 4, Height div 2 + 7);
  end;
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := RGBToColor(120, 132, 150);
  Canvas.TextOut(4, 2, '验证码');
end;

initialization
  { .lfm 里 object captcha1: TLWCaptcha 这样的条目要在运行时按类名找到类，
    和 TLWForm / TLWLoginForm / TLWFileUpload 一样在这里注册（不依赖
    IDE 的 RegisterComponents —— 运行时没有设计期包）}
  RegisterClass(TLWCaptcha);
  GCaptchaLock := TCriticalSection.Create;
  GCaptchaCodes := TStringList.Create;
  GCaptchaCodes.NameValueSeparator := '=';
  GCaptchaCodes.CaseSensitive := True;
  Randomize;

finalization
  GCaptchaCodes.Free;
  GCaptchaLock.Free;

end.
