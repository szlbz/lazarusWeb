{
  lazarusWeb :: lwfileupload
  ------------------------------------------------------------------
  TLWFileUpload —— 浏览器端"选择文件 → 上传 → 服务端事件"的按钮控件。

  为什么做成 TButton 的后代？
    · 设计期可以像普通按钮一样拖到窗体上、设 Caption/坐标、挂事件；
    · nogui 下 TButton 能正常构造，不需要任何新的 widgetset 支持；
    · 浏览器端渲染成一个带上传图标的 Ext 按钮，点击弹系统文件对话框。

  数据流（与 uniGUI 的 TUniFileUpload 一致）：
    1. 浏览器选中文件 -> 原生 XHR POST /lw/api/upload?sid=..&id=<本控件 id>
    2. 服务端把文件落到会话上传目录（或 TargetFolder），
       把完整路径记进 UploadedFiles；
    3. 触发 OnUpload(Sender, 文件全路径) —— 业务代码在这里读文件、入库、校验；
    4. 服务端返回新的组件树，浏览器照常做增量协调。

  下载见 lwform.SendFile（lwdownload 单元里的令牌表）。
}
unit lwfileupload;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StdCtrls;

type
  { 单个文件上传完成。AFileName 是服务端上的完整路径（不是浏览器给的名字），
    直接用 TFileStream / AssignFile 打开即可。多选时每个文件各触发一次。 }
  TLWFileUploadEvent = procedure(Sender: TObject; const AFileName: string) of object;

  TLWFileUpload = class(TButton)
  private
    FFilter: string;
    FMaxSizeKB: Integer;
    FMultiple: Boolean;
    FTargetFolder: string;
    FFiles: TStringList;
    FLastFileName: string;
    FOnUpload: TLWFileUploadEvent;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { 由服务端在收到文件后调用 }
    procedure AddUploadedFile(const APath: string);
    procedure ClearUploaded;

    { 最近一次上传成功的文件全路径 }
    property LastFileName: string read FLastFileName;
    { 本控件本次会话里上传过的所有文件，按顺序 }
    property UploadedFiles: TStringList read FFiles;
  published
    { 文件类型过滤，Windows 风格，如 '文本文件|*.txt;*.csv|所有文件|*.*'；
      留空表示不限制。也接受简单写法 '*.csv'。 }
    property Filter: string read FFilter write FFilter;
    { 单文件大小上限（KB），0 表示不限制 }
    property MaxSizeKB: Integer read FMaxSizeKB write FMaxSizeKB default 0;
    { 是否允许一次选多个文件 }
    property Multiple: Boolean read FMultiple write FMultiple default False;
    { 服务端保存目录；留空则用"会话临时目录/控件名" }
    property TargetFolder: string read FTargetFolder write FTargetFolder;
    property OnUpload: TLWFileUploadEvent read FOnUpload write FOnUpload;
  end;

implementation

constructor TLWFileUpload.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FFiles := TStringList.Create;
  FMaxSizeKB := 0;
  FMultiple := False;
  if Caption = '' then
    Caption := '上传文件…';
end;

destructor TLWFileUpload.Destroy;
begin
  FFiles.Free;
  inherited Destroy;
end;

procedure TLWFileUpload.AddUploadedFile(const APath: string);
begin
  FLastFileName := APath;
  if FFiles.IndexOf(APath) < 0 then
    FFiles.Add(APath);
end;

procedure TLWFileUpload.ClearUploaded;
begin
  FFiles.Clear;
  FLastFileName := '';
end;

initialization
  { lfm 里的自定义控件按类名实例化（GetClass），必须有运行时注册。
    设计期的那份注册在 lwdesign 包里，可执行文件不加载它。 }
  RegisterClass(TLWFileUpload);

end.
