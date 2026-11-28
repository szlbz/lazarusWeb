{ lwehlib.inc —— EhLib 可选支持的编译开关

  这个文件只控制 lwdsgnehlib.pas 里注册哪些能力；包本身的依赖
  （lwdesign / EhLib）写在 lwehlib.lpk 里，未安装 EhLib 的机器
  不编译这个包即可，lwdesign 不受影响。

  用法：注释掉某个 DEFINE 后重新编译 lwehlib.lpk。 }

{$DEFINE LW_EHLIB_DBGRIDEH}
