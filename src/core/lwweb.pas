{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwweb
  ------------------------------------------------------------------
  富内容显示控件，对应 uniGUI 的：
    TLWHTMLFrame  <->  uniHTMLFrame   面板里渲染一段任意 HTML
    TLWPDFFrame   <->  uniPDFFrame    面板里内嵌显示一个 PDF

  TLWHTMLFrame 的 HTML 就是 TStrings，设计期可以双击编辑，
  运行时改 HTML.Text 再等下一次协调（或触发任意事件刷新）即可。

  TLWPDFFrame 的两个来源：
    PDFFile : 服务端本地文件（推荐）。不把路径放进 URL —— 和
              SendFile 一样走 lwdownload 的令牌表，浏览器只拿到
              /lw/view?t=<令牌>。查看令牌是"可重复访问"的：
              每次序列化都 Touch 续期，会话活着就不会被 Sweep 收走；
              换文件（PDFFile 改变）自动换新令牌。
    PDFURL  : 外部 http(s) 地址，直接交给 iframe。

  浏览器端（lw.js）把这两个控件分别渲染成
    htmlframe -> Ext panel（html 配置）
    pdfframe  -> <iframe>（用浏览器自带的 PDF 查看器，不引第三方库）
}
unit lwweb;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, lwdownload;

type
  { TCustomPanel 只是给 writer 一个"可定位、可设底色"的宿主；
    它的子控件照常序列化，但浏览器端不渲染子控件（面板内容被
    HTML/iframe 占满），demo 里也不要往里放控件 }
  TLWHTMLFrame = class(TCustomPanel)
  private
    FHTML: TStrings;
    procedure SetHTML(AValue: TStrings);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property HTML: TStrings read FHTML write SetHTML;
    property Align;
    property Anchors;
    property BevelOuter;
    property BorderStyle;
    property Color;
    property Constraints;
    property Enabled;
    property Font;
    property ParentColor;
    property ParentFont;
    property PopupMenu;
    property ShowHint;
    property TabOrder;
    property TabStop;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnEnter;
    property OnExit;
    property OnResize;
  end;

  TLWPDFFrame = class(TCustomPanel)
  private
    FPDFFile: string;
    FPDFURL: string;
    FURLSuffix: string;
    FToken: string;        { 当前查看令牌 }
    FTokenFile: string;    { 令牌对应的文件（换文件就换令牌） }
    procedure SetPDFFile(const AValue: string);
  public
    constructor Create(AOwner: TComponent); override;
    { 给 writer 用：算出 iframe 的 src。可能返回空串（没有文件）。
      附带副作用：首次调用登记查看令牌，之后每次调用 Touch 续期。 }
    function ViewURL: string;
    { 立即作废旧令牌，下次 ViewURL 重新登记 }
    procedure RevokeToken;
  published
    { 服务端本地文件全路径 }
    property PDFFile: string read FPDFFile write SetPDFFile;
    { 外部地址；设置了它就优先于 PDFFile }
    property PDFURL: string read FPDFURL write FPDFURL;
    { 追加在 src 末尾的片段，比如 '#print'：页面里的脚本据此自动打印。
      配合"每次预览都生成新文件"用 —— 文件名变了，iframe 才会真的重载 }
    property URLSuffix: string read FURLSuffix write FURLSuffix;
    property Align;
    property Anchors;
    property BevelOuter;
    property BorderStyle;
    property Color;
    property Constraints;
    property Enabled;
    property Font;
    property ParentColor;
    property ParentFont;
    property PopupMenu;
    property ShowHint;
    property TabOrder;
    property TabStop;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnEnter;
    property OnExit;
    property OnResize;
  end;

implementation

{ ---------------- TLWHTMLFrame ---------------- }

constructor TLWHTMLFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHTML := TStringList.Create;
  Caption := '';
  Width := 320;
  Height := 240;
end;

destructor TLWHTMLFrame.Destroy;
begin
  FHTML.Free;
  inherited Destroy;
end;

procedure TLWHTMLFrame.SetHTML(AValue: TStrings);
begin
  FHTML.Assign(AValue);
end;

{ ---------------- TLWPDFFrame ---------------- }

constructor TLWPDFFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := '';
  Width := 480;
  Height := 360;
end;

procedure TLWPDFFrame.SetPDFFile(const AValue: string);
begin
  if AValue = FPDFFile then Exit;
  FPDFFile := AValue;
  RevokeToken;
end;

procedure TLWPDFFrame.RevokeToken;
begin
  if FToken <> '' then
    try
      LWDownloadRelease(FToken);
    except
    end;
  FToken := '';
  FTokenFile := '';
end;

function TLWPDFFrame.ViewURL: string;
begin
  { 外部地址优先，不进令牌表 }
  if FPDFURL <> '' then
    Exit(FPDFURL);

  if (FPDFFile = '') or (not FileExists(FPDFFile)) then
    Exit('');

  { 同一个文件沿用同一个令牌（iframe 刷新、翻页都不用重新登记），
    每次序列化 Touch 一次把过期时间续上 }
  if (FToken = '') or (FTokenFile <> FPDFFile) then
  begin
    RevokeToken;
    FToken := LWDownloadRegister(FPDFFile, ExtractFileName(FPDFFile));
    FTokenFile := FPDFFile;
    if FToken = '' then Exit('');
  end
  else
    LWDownloadTouch(FToken);

  Result := '/lw/view?t=' + FToken + FURLSuffix;
end;

initialization
  { lfm 里的自定义控件按类名实例化（GetClass），必须有运行时注册 }
  RegisterClass(TLWHTMLFrame);
  RegisterClass(TLWPDFFrame);

end.
