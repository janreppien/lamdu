{-# LANGUAGE OverloadedStrings #-}
module Editor.CodeEdit.ExpressionEdit.ApplyEdit(make) where

import Editor.Anchors (ViewTag)
import Editor.CTransaction (TWidget, getP, assignCursor, transaction)
import Editor.CodeEdit.ExpressionEdit.ExpressionMaker (ExpressionEditMaker)
import Editor.MonadF (MonadF)
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.Infix as Infix
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.UI.Bottle.Widget as Widget

make
  :: MonadF m
  => ExpressionEditMaker m
  -> Sugar.Apply m
  -> Widget.Id
  -> TWidget ViewTag m
make makeExpressionEdit (Sugar.Apply func arg) myId = do
  argI <- getP $ Sugar.rExpressionPtr arg
  assignCursor myId (WidgetIds.fromIRef argI) $ do
    funcI <- getP $ Sugar.rExpressionPtr func
    -- TODO: This will come from sugar
    isInfix <- transaction $ Infix.isInfixFunc funcI
    funcEdit <- makeExpressionEdit func
    argEdit <- makeExpressionEdit arg
    return . BWidgets.hbox $
      (if isInfix then reverse else id)
      [funcEdit, BWidgets.spaceWidget, argEdit]
