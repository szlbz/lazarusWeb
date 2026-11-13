{
  lazarusWeb :: 左侧折叠菜单组件 TLWSideMenu
  ------------------------------------------------------------------
  把「左侧深色折叠菜单」做成真正的 LCL 组件，设计期体验与 TMainMenu 一致：

    设计期（Lazarus IDE）
      * TLWSideMenu 是 TMenu 的后裔，双击组件即打开 IDE 原生「菜单编辑器」
        （IDE 里 RegisterComponentEditor(TMenu, ...)，按继承生效），
        添加/删除/移动菜单项、建子菜单、设 Caption / ShortCut /
        Enabled / Checked 与 TMainMenu 完全一样；
      * 图标：菜单编辑器里「Add icon from file…」给单个菜单项设置 Bitmap，
        图标随 lfm 存盘（TMenuItem.Bitmap 是 published 属性）；
      * 叶子项的 OnClick 在对象观察器里照常挂，可以所有项共用一个 handler，
        运行时用 (Sender as TMenuItem).Name 或 Tag 区分是哪一个；
      * 组件非可视（和 TMainMenu 一样），落在窗体上是一个可选中的小图标。

    运行期（浏览器）
      * 顶层菜单项 = 可折叠分组（有子项的节点渲染成组标题，点击展开/收起，
        展开状态记在 localStorage）；
      * 叶子菜单项 = 可点击行，点击回发服务端 OnClick（框架通用事件通道，
        和其他控件一模一样），Checked=True 的项显示为选中高亮；
      * 侧栏占左侧 SideWidth 像素，窗体其余控件的客户区自动右移让位
        （框架按侧栏宽度收缩客户区，alTop/alClient 的对齐照常生效）。

  注意：nogui widgetset 下 TImageList 不可用（WSRegisterCustomImageListResolution
  返回 False，IL.Add 直接抛 FPImageException），所以图标请用菜单项的 Bitmap
  （IDE 菜单编辑器默认写的就是它），不要用 Images + ImageIndex。
}
unit lwsidemenu;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Menus;

type

  { TLWSideMenu }

  TLWSideMenu = class(TMenu)
  private
    FSideWidth: Integer;
    FItemHeight: Integer;
    FHeaderCaption: string;
    FFirstGroupOpen: Boolean;
  public
    constructor Create(AOwner: TComponent); override;
  published
    { 侧栏宽度（像素），窗体其余控件自动右移这么多 }
    property SideWidth: Integer read FSideWidth write FSideWidth default 260;
    { 菜单行高（像素），0 = 由前端按字号决定 }
    property ItemHeight: Integer read FItemHeight write FItemHeight default 40;
    { 侧栏顶部的标题文字，留空则不显示标题条 }
    property HeaderCaption: string read FHeaderCaption write FHeaderCaption;
    { 第一组默认展开（其余组默认折叠，用户点开的优先于这里） }
    property FirstGroupOpen: Boolean read FFirstGroupOpen write FFirstGroupOpen default True;
  end;

implementation

constructor TLWSideMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSideWidth := 260;
  FItemHeight := 40;
  FFirstGroupOpen := True;
end;

initialization
  { 注册到 LCL 流系统：设计器打开带 TLWSideMenu 的 .lfm 时需要按类名实例化 }
  RegisterClass(TLWSideMenu);

end.
