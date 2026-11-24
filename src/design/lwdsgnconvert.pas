{ lazarusWeb :: lwdsgnconvert
  ------------------------------------------------------------------
  设计期 IDE 集成：Tools 菜单「将 Lazarus 工程转换为 lazarusWeb…」。

  转换向导不是外部 exe —— 直接把 tools\ulwconvertgui.pas 的
  TConvertPanelForm 编进 lwdesign 包，菜单点击后在本进程 ShowModal。
  与命令行版 / GUI 独立版共用同一个 ulwconvertgui + lwconvert_core，
  改写结果一字不差，只是宿主从 lwconvert_gui.exe 变成 IDE。

  本单元只做两件事：
    1. 推断 lazarusWeb 仓库根（优先从 lwdesign.lpk 的位置反推：
       <root>\src\design\ -> <root>\，其次 LW_ROOT / LAZARUSWEB_ROOT）；
    2. 打开窗体时把仓库根、当前工程目录预填进去，用户少点两下。

  为什么必须预填 edRoot：原 GUI 版用 ParamStr(0) 找仓库根，
  在 IDE 里 ParamStr(0) 是 lazarus.exe，推断必然落空。 }
unit lwdsgnconvert;

{$mode objfpc}{$H+}

interface

procedure Register;

implementation

uses
  Classes, SysUtils, MenuIntf, PackageIntf, LazIDEIntf, SrcEditorIntf,
  LazFileUtils, ulwconvertgui;

type
  TConvertMenuHandler = class
  public
    procedure ExecConvert(Sender: TObject);
  end;

var
  ConvertMenuHandler: TConvertMenuHandler = nil;

{ 从已安装包的 .lpk 位置反推仓库根。lwdesign.lpk 固定在 <root>\src\design\ }
function RepoRootFromPackage: string;
var
  pkg: TIDEPackage;
  lpkDir, root: string;
begin
  Result := '';
  try
    pkg := PackageEditingInterface.FindPackageWithName('lwdesign');
  except
    pkg := nil;
  end;
  if pkg = nil then
    Exit;
  lpkDir := ExtractFilePath(pkg.Filename);
  if lpkDir = '' then
    Exit;
  root := ExtractFilePath(ExcludeTrailingPathDelimiter(lpkDir)); { <root>\src\ }
  root := ExtractFilePath(ExcludeTrailingPathDelimiter(root));   { <root>\    }
  if FileExistsUTF8(IncludeTrailingPathDelimiter(root) +
      'src' + PathDelim + 'core' + PathDelim + 'lwapp.pas') then
    Result := ExcludeTrailingPathDelimiter(root);
end;

function RepoRootFromEnv(const AName: string): string;
var
  root: string;
begin
  Result := '';
  root := SysUtils.GetEnvironmentVariable(AName);
  if root = '' then
    Exit;
  root := IncludeTrailingPathDelimiter(root);
  if FileExistsUTF8(root + 'src' + PathDelim + 'core' + PathDelim + 'lwapp.pas') then
    Result := ExcludeTrailingPathDelimiter(root);
end;

function DetectRepoRoot: string;
begin
  Result := RepoRootFromPackage;
  if Result = '' then
    Result := RepoRootFromEnv('LW_ROOT');
  if Result = '' then
    Result := RepoRootFromEnv('LAZARUSWEB_ROOT');
end;

{ 当前工程的主文件目录；没有工程时退回当前编辑器文件目录 }
function DetectProjectDir: string;
var
  s: string;
begin
  Result := '';
  if (LazarusIDE <> nil) and (LazarusIDE.ActiveProject <> nil) and
     (LazarusIDE.ActiveProject.MainFile <> nil) then
  begin
    s := LazarusIDE.ActiveProject.MainFile.Filename;
    if s <> '' then
      Exit(ExcludeTrailingPathDelimiter(ExtractFilePath(s)));
  end;
  if (SourceEditorManagerIntf <> nil) and
     (SourceEditorManagerIntf.ActiveEditor <> nil) then
  begin
    s := SourceEditorManagerIntf.ActiveEditor.FileName;
    if s <> '' then
      Result := ExcludeTrailingPathDelimiter(ExtractFilePath(s));
  end;
end;

procedure TConvertMenuHandler.ExecConvert(Sender: TObject);
var
  frm: TConvertPanelForm;
  root, proj: string;
begin
  frm := TConvertPanelForm.Create(nil);
  try
    root := DetectRepoRoot;
    if root <> '' then
      frm.edRoot.Text := root;
    proj := DetectProjectDir;
    if (proj <> '') and DirectoryExistsUTF8(proj) then
      frm.edSrc.Text := proj;
    frm.ShowModal;
  finally
    frm.Free;
  end;
end;

procedure Register;
begin
  RegisterIDEMenuCommand(itmSecondaryTools, 'lwConvertProject',
    '将 Lazarus 工程转换为 lazarusWeb…',
    @ConvertMenuHandler.ExecConvert);
end;

initialization
  ConvertMenuHandler := TConvertMenuHandler.Create;

finalization
  FreeAndNil(ConvertMenuHandler);

end.
