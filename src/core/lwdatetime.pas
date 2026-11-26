{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwdatetime
  ------------------------------------------------------------------
  DateTimeCtrls 包（TDateTimePicker）的桥接单元。

  做三件事（都在 initialization 里一次登记完）：
    1. kind 映射：TDateTimePicker -> 'datetimeedit'，浏览器端按 kind 属性
       渲染成原生的 date / time / datetime-local 输入；
    2. 属性下发：iso（统一 ISO 串）+ dtkind（date/time/datetime）+ 只读等，
       与 TDateEdit/TTimeEdit 的 iso 约定一致，服务端/浏览器都不吃本地化格式；
    3. 值回写：浏览器回传的 ISO 串写回 DateTime / Date / Time。

  为什么单独一个单元、且由业务工程自己 uses：
    核心包（lwcore / lwserver）不依赖 DateTimeCtrls —— 与 VirtualTreeView
    同样的策略，不引用它的工程连这个包都不必装。转换器（lwconvert）在 .lfm
    里发现 TDateTimePicker 时会自动把本单元加进 .lpr 的 uses，并把
    DateTimeCtrls 写进生成工程的 RequiredPackages。

  用法（手工接入时的两行）：
    uses ..., lwdatetime;              // 登记，程序启动即生效
    .lpi 的 RequiredPackages 增加 DateTimeCtrls
}
unit lwdatetime;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, DateTimePicker;

{ 登记 TDateTimePicker 的 kind 与回写。幂等；initialization 自动调用 }
procedure LWRegisterDateTimePicker;

implementation

uses
  fpjson, lwwriter, lwdispatch;

var
  GRegistered: Boolean = False;

function DTPKindStr(K: TDateTimeKind): string;
begin
  case K of
    dtkTime: Result := 'time';
    dtkDateTime: Result := 'datetime';
  else
    Result := 'date';
  end;
end;

{ 序列化：iso 按 kind 只下发对应的那一段 —— 浏览器端 date 输入拿到
  'yyyy-mm-dd hh:nn:ss' 会解析失败，显示成空 }
procedure DTPProps(C: TControl; O: TJSONObject);
var
  P: TDateTimePicker;
begin
  P := TDateTimePicker(C);
  LWBindPublishedProps(C, O, ['ReadOnly', 'ShowCheckBox', 'Checked']);
  O.Add('dtkind', DTPKindStr(P.Kind));
  { NullDate（DB 里的空日期）或勾选框没勾：不下发值，浏览器显示空 }
  if (P.ShowCheckBox and (not P.Checked)) or (P.DateTime > 1e300) then
  begin
    O.Add('iso', '');
    Exit;
  end;
  try
    case P.Kind of
      dtkTime: O.Add('iso', FormatDateTime('hh:nn:ss', P.Time));
      dtkDateTime: O.Add('iso', FormatDateTime('yyyy-mm-dd hh:nn:ss', P.DateTime));
    else
      O.Add('iso', FormatDateTime('yyyy-mm-dd', P.Date));
    end;
  except
    { 脏日期（数据集塞过非法值）时 FormatDateTime 会抛 EConvertError，
      降级成空 iso，别让整个控件节点序列化失败 }
    O.Add('iso', '');
  end;
end;

procedure DTPWrite(C: TComponent; const S: string);
var
  P: TDateTimePicker;
  v: TDateTime;
begin
  P := TDateTimePicker(C);
  if Trim(S) = '' then
  begin
    { 浏览器清空：勾选框语义下就是"未设置"，取消勾选；没有勾选框时保持原值 }
    if P.ShowCheckBox then
      P.Checked := False;
    Exit;
  end;
  v := LWISOToDateTime(S, P.DateTime);
  if P.Kind = dtkTime then
    P.Time := v
  else
    P.DateTime := v;
  if P.ShowCheckBox then
    P.Checked := True;
end;

procedure LWRegisterDateTimePicker;
begin
  if GRegistered then Exit;
  GRegistered := True;
  LWRegisterControlKind(TDateTimePicker, 'datetimeedit', @DTPProps);
  LWRegisterValueWriter(TDateTimePicker, @DTPWrite);
end;

initialization
  LWRegisterDateTimePicker;

end.
