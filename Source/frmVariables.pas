{-----------------------------------------------------------------------------
 Unit Name: frmVariables
 Author:    Kiriakos Vlahos
 Date:      09-Mar-2005
 Purpose:   Variables Window
 History:
-----------------------------------------------------------------------------}

unit frmVariables;

interface

uses
  WinApi.Windows,
  WinApi.Messages,
  System.UITypes,
  System.SysUtils,
  System.Variants,
  System.Classes,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.Menus,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  JvComponentBase,
  JvDockControlForm,
  JvAppStorage,
  SpTBXDkPanels,
  SpTBXSkins,
  SpTBXPageScroller,
  SpTBXItem,
  SpTBXControls,
  VTHeaderPopup,
  VirtualTrees,
  frmIDEDockWin,
  cPyBaseDebugger;

type
  TVariablesWindow = class(TIDEDockWindow, IJvAppStorageHandler)
    VTHeaderPopupMenu: TVTHeaderPopupMenu;
    VariablesTree: TVirtualStringTree;
    DocPanel: TSpTBXPageScroller;
    SpTBXSplitter: TSpTBXSplitter;
    reInfo: TRichEdit;
    Panel1: TPanel;
    procedure FormCreate(Sender: TObject);
    procedure VariablesTreeInitNode(Sender: TBaseVirtualTree; ParentNode,
      Node: PVirtualNode; var InitialStates: TVirtualNodeInitStates);
    procedure VariablesTreeGetImageIndex(Sender: TBaseVirtualTree;
      Node: PVirtualNode; Kind: TVTImageKind; Column: TColumnIndex;
      var Ghosted: Boolean; var ImageIndex: TImageIndex);
    procedure VariablesTreeGetText(Sender: TBaseVirtualTree;
      Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType;
      var CellText: string);
    procedure FormActivate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure VariablesTreePaintText(Sender: TBaseVirtualTree;
      const TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
      TextType: TVSTTextType);
    procedure VariablesTreeInitChildren(Sender: TBaseVirtualTree;
      Node: PVirtualNode; var ChildCount: Cardinal);
    procedure reInfoResizeRequest(Sender: TObject; Rect: TRect);
    procedure VariablesTreeFreeNode(Sender: TBaseVirtualTree;
      Node: PVirtualNode);
    procedure VariablesTreeAddToSelection(Sender: TBaseVirtualTree;
      Node: PVirtualNode);
  private
    { Private declarations }
    CurrentModule, CurrentFunction : string;
    GlobalsNameSpace, LocalsNameSpace : TBaseNameSpaceItem;
  protected
    // IJvAppStorageHandler implementation
    procedure ReadFromAppStorage(AppStorage: TJvCustomAppStorage; const BasePath: string);
    procedure WriteToAppStorage(AppStorage: TJvCustomAppStorage; const BasePath: string);
  public
    { Public declarations }
    procedure ClearAll;
    procedure UpdateWindow;
  end;

var
  VariablesWindow: TVariablesWindow = nil;

implementation

uses
  System.Math,
  Vcl.Themes,
  JvJVCLUtils,
  PythonEngine,
  JvGnugettext,
  StringResources,
  dmCommands,
  frmCallStack,
  uCommonFunctions,
  cVirtualStringTreeHelper,
  cPyControl;

{$R *.dfm}
Type
  PNodeData = ^TNodeData;
  TNodeData = record
    Name : string;
    ObjectType : string;
    Value : string;
    ImageIndex : Integer;
    NameSpaceItem : TBaseNameSpaceItem;
  end;

procedure TVariablesWindow.FormCreate(Sender: TObject);
begin
  inherited;
  // Let the tree know how much data space we need.
  VariablesTree.NodeDataSize := SizeOf(TNodeData);
end;

procedure TVariablesWindow.VariablesTreeInitChildren(Sender: TBaseVirtualTree;
  Node: PVirtualNode; var ChildCount: Cardinal);
var
  Data: PNodeData;
begin
  Data := Node.GetData;
  if Assigned(Data.NameSpaceItem) then
    ChildCount := Data.NameSpaceItem.ChildCount;
end;

procedure TVariablesWindow.VariablesTreeInitNode(Sender: TBaseVirtualTree;
  ParentNode, Node: PVirtualNode;
  var InitialStates: TVirtualNodeInitStates);
var
  Data, ParentData: PNodeData;
begin
  Data := Node.GetData;
  if not VariablesTree.Enabled then begin
    Data.NameSpaceItem := nil;
    Exit;
  end;

  if VariablesTree.GetNodeLevel(Node) = 0 then begin
    Assert(Node.Index <= 1);
    if CurrentModule <> '' then begin
      if Node.Index = 0 then begin
        Assert(Assigned(GlobalsNameSpace));
        Data.NameSpaceItem := GlobalsNameSpace;
        InitialStates := [ivsHasChildren];
      end else if Node.Index = 1 then begin
        Assert(Assigned(LocalsNameSpace));
        Data.NameSpaceItem := LocalsNameSpace;
        InitialStates := [ivsExpanded, ivsHasChildren];
      end;
    end else begin
      Assert(Node.Index = 0);
      Assert(Assigned(GlobalsNameSpace));
      Data.NameSpaceItem := GlobalsNameSpace;
      InitialStates := [ivsExpanded, ivsHasChildren];
    end;
  end else begin
    ParentData := ParentNode.GetData;
    Data.NameSpaceItem := ParentData.NameSpaceItem.ChildNode[Node.Index];
    if Data.NameSpaceItem.ChildCount > 0 then
      InitialStates := [ivsHasChildren]
    else
      InitialStates := [];
  end;
  // Node Text
  Data.Name := Data.NameSpaceItem.Name;
  Data.ObjectType := Data.NameSpaceItem.ObjectType;
  try
    Data.Value := Data.NameSpaceItem.Value;
  except
    Data.Value := '';
  end;
  // ImageIndex
  if Data.NameSpaceItem.IsDict then
    Data.ImageIndex := Ord(TCodeImages.Namespace)
  else if Data.NameSpaceItem.IsModule then
    Data.ImageIndex := Ord(TCodeImages.Module)
  else if Data.NameSpaceItem.IsMethod then
    Data.ImageIndex := Ord(TCodeImages.Method)
  else if Data.NameSpaceItem.IsFunction then
    Data.ImageIndex := Ord(TCodeImages.Func)
  else if Data.NameSpaceItem.IsClass or Data.NameSpaceItem.Has__dict__ then
     Data.ImageIndex := Ord(TCodeImages.Klass)
  else if (Data.ObjectType = 'list') or (Data.ObjectType = 'tuple') then
    Data.ImageIndex := Ord(TCodeImages.List)
  else begin
    if Assigned(ParentNode) and
      (PNodeData(ParentNode.GetData).NameSpaceItem.IsDict
        or PNodeData(ParentNode.GetData).NameSpaceItem.IsModule)
    then
      Data.ImageIndex := Ord(TCodeImages.Variable)
    else
      Data.ImageIndex := Ord(TCodeImages.Field);
  end;
end;

procedure TVariablesWindow.VariablesTreePaintText(Sender: TBaseVirtualTree;
  const TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
  TextType: TVSTTextType);
var
  Data : PNodeData;
begin
  Data := Node.GetData;
  if VariablesTree.Enabled and Assigned(Data) and Assigned(Data.NameSpaceItem) then
    if nsaChanged in Data.NameSpaceItem.Attributes then
      TargetCanvas.Font.Color := clRed
    else if nsaNew in Data.NameSpaceItem.Attributes then
      TargetCanvas.Font.Color := StyleServices.GetSystemColor(clHotlight);
end;

procedure TVariablesWindow.ReadFromAppStorage(AppStorage: TJvCustomAppStorage;
  const BasePath: string);
Var
  TempWidth : integer;
begin
  TempWidth := PPIScaled(AppStorage.ReadInteger(BasePath+'\DocPanelWidth', DocPanel.Width));
  DocPanel.Width := Min(TempWidth,  Max(Width-PPIScaled(100), PPIScaled(3)));
  if AppStorage.ReadBoolean(BasePath+'\Types Visible') then
    VariablesTree.Header.Columns[1].Options := VariablesTree.Header.Columns[1].Options + [coVisible]
  else
    VariablesTree.Header.Columns[1].Options := VariablesTree.Header.Columns[1].Options - [coVisible];
  VariablesTree.Header.Columns[0].Width :=
    PPIScaled(AppStorage.ReadInteger(BasePath+'\Names Width', 160));
  VariablesTree.Header.Columns[1].Width :=
    PPIScaled(AppStorage.ReadInteger(BasePath+'\Types Width', 100));
end;

procedure TVariablesWindow.reInfoResizeRequest(Sender: TObject; Rect: TRect);
begin
  Rect.Height := Max(Rect.Height, reInfo.Parent.ClientHeight);
  reInfo.BoundsRect := Rect;
end;

procedure TVariablesWindow.WriteToAppStorage(AppStorage: TJvCustomAppStorage;
  const BasePath: string);
begin
  AppStorage.WriteInteger(BasePath+'\DocPanelWidth', PPIUnScaled(DocPanel.Width));
  AppStorage.WriteBoolean(BasePath+'\Types Visible', coVisible in VariablesTree.Header.Columns[1].Options);
  AppStorage.WriteInteger(BasePath+'\Names Width',
    PPIUnScaled(VariablesTree.Header.Columns[0].Width));
  AppStorage.WriteInteger(BasePath+'\Types Width',
    PPIUnScaled(VariablesTree.Header.Columns[1].Width));
end;

procedure TVariablesWindow.VariablesTreeGetImageIndex(
  Sender: TBaseVirtualTree; Node: PVirtualNode; Kind: TVTImageKind;
  Column: TColumnIndex; var Ghosted: Boolean; var ImageIndex: TImageIndex);
var
  Data : PNodeData;
begin
  Data := Node.GetData;
  if Assigned(Data.NameSpaceItem) and (Column = 0) and (Kind in [ikNormal, ikSelected]) then begin
    ImageIndex := Data.ImageIndex;
  end else
    ImageIndex := -1;
end;

procedure TVariablesWindow.VariablesTreeGetText(Sender: TBaseVirtualTree;
  Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType;
  var CellText: string);
var
  Data : PNodeData;
begin
  if TextType <> ttNormal then Exit;
  Data := Node.GetData;
  if Assigned(Data) and Assigned(Data.NameSpaceItem) then
    case Column of
      0 : CellText := Data.Name;
      1 : CellText := Data.ObjectType;
      2 : CellText := Data.Value;
    end
  else
    CellText := 'NA';
end;

procedure TVariablesWindow.UpdateWindow;
Var
  CurrentFrame : TBaseFrameInfo;
  SameFrame : boolean;
  RootNodeCount : Cardinal;
  OldGlobalsNameSpace, OldLocalsNamespace : TBaseNameSpaceItem;
begin
  if not (PyControl.InternalPython.Loaded and
          Assigned(CallStackWindow) and
          Assigned(PyControl.ActiveInterpreter) and
          Assigned(PyControl.ActiveDebugger)) then
  begin
     ClearAll;
     Exit;
  end;

  if PyControl.Running then begin
    // should not update
    VariablesTree.Enabled := False;
    Exit;
  end else
    VariablesTree.Enabled := True;

  // Get the selected frame
  CurrentFrame := CallStackWindow.GetSelectedStackFrame;

  SameFrame := (not Assigned(CurrentFrame) and
                (CurrentModule = '') and
                (CurrentFunction = '')) or
                (Assigned(CurrentFrame) and
                (CurrentModule = CurrentFrame.FileName) and
                (CurrentFunction = CurrentFrame.FunctionName));

  OldGlobalsNameSpace := GlobalsNameSpace;
  OldLocalsNamespace := LocalsNameSpace;
  GlobalsNameSpace := nil;
  LocalsNameSpace := nil;

  // Turn off Animation to speed things up
  VariablesTree.TreeOptions.AnimationOptions :=
    VariablesTree.TreeOptions.AnimationOptions - [toAnimatedToggle];

  if Assigned(CurrentFrame) then begin
    CurrentModule := CurrentFrame.FileName;
    CurrentFunction := CurrentFrame.FunctionName;
    // Set the initial number of nodes.
    GlobalsNameSpace := PyControl.ActiveDebugger.GetFrameGlobals(CurrentFrame);
    LocalsNameSpace := PyControl.ActiveDebugger.GetFrameLocals(CurrentFrame);
    if Assigned(GlobalsNameSpace) and Assigned(LocalsNameSpace) then
      RootNodeCount := 2
    else
      RootNodeCount := 0;
  end else begin
    CurrentModule := '';
    CurrentFunction := '';
    try
      GlobalsNameSpace := PyControl.ActiveInterpreter.GetGlobals;
      RootNodeCount := 1;
    except
      RootNodeCount := 0;
    end;
  end;

  if (RootNodeCount > 0) and SameFrame and (RootNodeCount = VariablesTree.RootNodeCount) then begin
    if Assigned(GlobalsNameSpace) and Assigned(OldGlobalsNameSpace) then
      GlobalsNameSpace.CompareToOldItem(OldGlobalsNameSpace);
    if Assigned(LocalsNameSpace) and Assigned(OldLocalsNameSpace) then
      LocalsNameSpace.CompareToOldItem(OldLocalsNameSpace);
    VariablesTree.BeginUpdate;
    try
      // The following will Reinitialize only initialized nodes
      // Do not use ReinitNode because it Reinits non-expanded children
      // potentially leading to deep recursion
      VariablesTree.ReinitInitializedChildren(nil, True);
      // No need to initialize nodes they will be initialized as needed
      // The following initializes non-initialized nodes without expansion
      //VariablesTree.InitRecursive(nil);
      VariablesTree.InvalidateToBottom(VariablesTree.GetFirstVisible);
    finally
      VariablesTree.EndUpdate;
    end;
  end else begin
    VariablesTree.Clear;
    VariablesTree.RootNodeCount := RootNodeCount;
    //VariablesTree.InitRecursive(nil);
  end;
  FreeAndNil(OldGlobalsNameSpace);
  FreeAndNil(OldLocalsNameSpace);

  VariablesTree.TreeOptions.AnimationOptions :=
    VariablesTree.TreeOptions.AnimationOptions + [toAnimatedToggle];
  VariablesTreeAddToSelection(VariablesTree, nil);
end;

procedure TVariablesWindow.ClearAll;
begin
  VariablesTree.Clear;
  FreeAndNil(GlobalsNameSpace);
  FreeAndNil(LocalsNameSpace);
end;

procedure TVariablesWindow.FormActivate(Sender: TObject);
begin
  inherited;
  if not VariablesTree.Enabled then VariablesTree.Clear;

  if CanActuallyFocus(VariablesTree) then
    VariablesTree.SetFocus;
  //PostMessage(VariablesTree.Handle, WM_SETFOCUS, 0, 0);
end;

procedure TVariablesWindow.FormDestroy(Sender: TObject);
begin
  VariablesWindow := nil;
  ClearAll;
  inherited;
end;

procedure TVariablesWindow.VariablesTreeAddToSelection(Sender: TBaseVirtualTree;
  Node: PVirtualNode);
Var
  NameSpace,
  ObjectName,
  ObjectType,
  ObjectValue,
  DocString : string;
  Data : PNodeData;
begin
  if not Enabled then Exit;

  // Get the selected frame
  if CurrentModule <> '' then
    NameSpace := Format(_(SNamespaceFormat), [CurrentFunction, CurrentModule])
  else
    NameSpace := 'Interpreter globals';

  reInfo.Clear;
  AddFormatText(reInfo, _('Namespace') + ': ', [fsBold]);
  AddFormatText(reInfo, NameSpace, [fsItalic]);
  if Assigned(Node) then begin
    Data := Node.GetData;
    ObjectName := Data.Name;
    ObjectType := Data.ObjectType;
    ObjectValue := Data.Value;
    DocString :=  Data.NameSpaceItem.DocString;

    AddFormatText(reInfo, SLineBreak+_('Name')+': ', [fsBold]);
    AddFormatText(reInfo, ObjectName, [fsItalic]);
    AddFormatText(reInfo, SLineBreak + _('Type') + ': ', [fsBold]);
    AddFormatText(reInfo, ObjectType);
    AddFormatText(reInfo, SLineBreak + _('Value') + ':' + SLineBreak, [fsBold]);
    AddFormatText(reInfo, ObjectValue);
    AddFormatText(reInfo, SLineBreak + _('DocString') + ':' + SLineBreak, [fsBold]);
    AddFormatText(reInfo, Docstring);
  end;
end;

procedure TVariablesWindow.VariablesTreeFreeNode(Sender: TBaseVirtualTree;
  Node: PVirtualNode);
Var
  Data : PNodeData;
begin
  Data := Node.GetData;
  Finalize(Data^);
end;

end.


