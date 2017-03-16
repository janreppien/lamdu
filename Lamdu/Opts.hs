{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, FlexibleContexts, RecordWildCards #-}
module Lamdu.Opts
    ( IDEOpts(..), ioWindowMode, ioCopyJSOutputPath, ioWindowTitle
    , Command(..), _DeleteDb, _Undo, _IDE
    , Parsed(..), pCommand, pLamduDB
    , WindowMode(..), _VideoModeSize, _FullScreen
    , get
    ) where

import           Control.Applicative (optional)
import qualified Control.Lens as Lens
import           Options.Applicative ((<|>))
import qualified Options.Applicative as P

import           Lamdu.Prelude

data WindowMode = VideoModeSize | FullScreen

data IDEOpts = IDEOpts
    { _ioWindowMode :: WindowMode
    , _ioCopyJSOutputPath :: Maybe FilePath
    , _ioWindowTitle :: String
    }

data Command
    = DeleteDb
    | Undo Int
    | IDE IDEOpts

data Parsed = Parsed
    { _pCommand :: Command
    , _pLamduDB :: Maybe FilePath
    }

Lens.makeLenses ''IDEOpts
Lens.makePrisms ''Command
Lens.makePrisms ''WindowMode
Lens.makeLenses ''Parsed

subcommands :: P.Parser Command
subcommands =
    mconcat
    [ P.command "deletedb"
      (P.info (pure DeleteDb) (P.progDesc "Irreversibly delete the lamdu database"))
    , P.command "undo"
      (P.info
       (P.argument (Undo <$> P.auto) (P.metavar "COUNT"))
       (P.progDesc "Perform undos on the database"))
    ] & P.hsubparser

maybePath :: P.Mod P.OptionFields String -> P.Parser (Maybe FilePath)
maybePath m = optional (P.option P.str (P.metavar "PATH" <> m))

ideOpts :: P.Parser IDEOpts
ideOpts =
    IDEOpts
    <$> windowMode
    <*> maybePath
        (P.long "copyjsoutput" <>
         P.help "Output the internal executed JS to a file")
    <*> P.option P.str
        ( P.long "windowtitle"
          <> P.value "Lamdu"
          <> P.metavar "TITLE"
          <> P.showDefault
          <> P.help "Override window title"
        )

command :: P.Parser Command
command = (IDE <$> ideOpts) <|> subcommands

windowMode :: P.Parser WindowMode
windowMode =
    P.flag' FullScreen
    ( P.long "fullscreen"
      <> P.short 'f'
      <> P.help "Run Lamdu in a fullscreen window"
    )
    <|> pure VideoModeSize

parser :: P.Parser Parsed
parser =
    Parsed
    <$> command
    <*> maybePath (P.long "lamduDB" <> P.help "Override path to lamdu DB")

get :: IO Parsed
get =
    P.info
    (P.helper <*> parser)
    (P.progDesc "lamdu - the next generation IDE")
    & P.execParser
