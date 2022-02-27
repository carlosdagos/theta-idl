{-# LANGUAGE EmptyCase                 #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NamedFieldPuns            #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE QuasiQuotes               #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE ViewPatterns              #-}

-- | The core set of errors that can be encountered when working with
-- Theta defintions.
module Theta.Error where

import           Control.Exception.Base (Exception (..), displayException)
import           Control.Monad.Except   (MonadError, throwError)

import           Data.Text              (Text)
import qualified Data.Text              as Text
import           Data.Void              (Void)

import qualified Text.Megaparsec        as Megaparsec

import           Theta.Metadata         (Metadata, Version)
import qualified Theta.Metadata         as Metadata
import           Theta.Name             (ModuleName, Name)
import qualified Theta.Name             as Name
import           Theta.Pretty           (Pretty (..), p)
import           Theta.Types            (FieldName, ModuleDefinition,
                                         moduleDefinitionName)
import           Theta.Versions         (Range (..))

-- | The kind of error generated by Theta's parser.
type ParseError = Megaparsec.ParseErrorBundle Text Void

-- | Errors encountered when working with Theta defintions.
--
-- The 'target' parameter lets us include errors specific to an
-- input/output target (like Avro or Haskell).
data Error = ParseError ParseError
             -- ^ A parse error raised by parsec.
           | IOError IOError
             -- ^ An error in reading or writing files
             -- (including importing modules).
           | UnsupportedVersion Metadata Range Version
             -- ^ A module requires a language or encoding version
             -- that is not supported by this release of Theta.
           | InvalidModule [(ModuleDefinition, ModuleError)]
             -- ^ The module or its dependencies have
             -- validation errors. This includes the errors for
             -- /every/ invalid module, tagged with the name of
             -- the module.
           | InvalidName Text
             -- ^ The given name is not syntactically valid.
           | UnqualifiedName Text
             -- ^ The given name does not have a namespace where a
             -- namespace is required.
           | MissingModule Text ModuleName
             -- ^ The given module was not found.
           | MissingName Name
             -- ^ The given fully-qualified name was not found.
           | Target Text TargetError
             -- ^ An error specific to a target, along with the
             -- name of the target itself.
             --
             -- For example, we can't export types other than
             -- records or variants as a schema in Avro. Trying
             -- to do this would raise the following error:
             --
             -- @
             -- Target "Avro" (InvalidExport <type>)
             -- @
           deriving (Show)

instance Exception Error where displayException = Text.unpack . pretty

-- | A wrapper for some type of error generated by a target-specific
-- operation in Theta—errors specific to encoding to/from Avro,
-- converting between Haskell types...etc.
--
-- This error is wrapped in an existential type so that operations on
-- different targets can be composed. For example, we can combine
-- 'fromAvro' (which raises Avro-specific errors) with 'fromTheta'
-- (which raises type mismatch errors) to go from the Avro binary
-- format to Haskell types.
data TargetError =
  forall error. (Show error, Pretty error) => TargetError error

deriving instance Show TargetError

-- | Throw an error specific to a particular target (Avro, Haskell…
-- etc).
throw :: (Show error, Pretty error, MonadError Error m)
      => Text
         -- ^ The name of the target that causes this error ("Avro",
         -- "Haskell"… etc).
      -> error
      -> m a
throw targetName = throwError . Target targetName . TargetError

-- | Unsafely extract a value that might be a Theta 'Error', turning
-- errors into runtime exceptions.
--
-- This is meant to be used when the error represents a bug in Theta
-- itself as opposed to an issue with an input.
unsafe :: Either Error a -> a
unsafe = \case
  Left err  -> error $ Text.unpack $ pretty err
  Right res -> res
               -- Consider: Add a note to the error message that this
               -- is a bug that should be reported on GitHub

-- | Errors caught when validating a module that has already been
-- parsed. These are errors at the "Theta language" level: conflicting
-- or undefined names, duplicate record fields... etc.
data ModuleError =
    --                 record   field
    --                    ↓       ↓
    DuplicateRecordField Name FieldName
    -- ^ The record with the given name has more than one field with the
    -- same name.

    --             variant  case
    --                 ↓     ↓
  | DuplicateCaseName Name Name
    -- ^ The variant with the given name has more than one case with
    -- the same name.

    --               variant case field
    --                  ↓    ↓    ↓
  | DuplicateCaseField Name Name FieldName
    -- ^ A variant with a case that has multiple fields with the same
    -- name.

  | UndefinedType Name
    -- ^ A name used in the module has not been defined.

  | DuplicateTypeName Name
    -- ^ A type with the given name has been defined multiple times in
    -- the same module. Fully qualified names (that is, name +
    -- namespace) should be *globally unique* in a Theta module.
    --
    -- Note: types, fields and variant constructors do not share a
    -- namespace, so you can use the same name for a type /and/ a
    -- constructor in traditional Haskell style.
    deriving (Show)

-- * Pretty printing Theta errors

instance Pretty Error where
  pretty = \case
    ParseError err -> Text.pack $ Megaparsec.errorBundlePretty err
    IOError err    -> Text.pack $ displayException err

    UnsupportedVersion metadata range version ->
      [p|
        The ‘#{pretty $ Metadata.moduleName metadata}’ module requires

          #{name range} = #{pretty version}

        but this release of Theta only supports

          #{name range} ≥ #{pretty $ lower range} and < #{pretty $ upper range}
        |]
    InvalidModule errs ->
      [p|
        Errors in module definitions:

        #{Text.intercalate "\n" $ prettyModuleError <$> errs}
        |]
    InvalidName name ->
      [p|
        Syntax error: ‘#{name}’ is not a valid Theta name.
        |]
    UnqualifiedName name ->
      [p|
        ‘#{name}’ does not have a namespace. Please provide
        a fully-qualified name like ‘com.example.Foo’.
        |]
    MissingModule loadPath moduleName ->
      [p|
        The module ‘#{moduleName}’ was not found in ‘#{loadPath}’.
        |]
    MissingName Name.Name { Name.name, Name.moduleName } ->
      [p|
        Could not find ‘#{name}’ in module ‘#{moduleName}’.
        |]

    Target target (TargetError err) ->
        [p|
          Error converting to/from #{target}:

          #{pretty err}
          |]

-- | Creates a readable message for a single module error, noting both
-- the problem and the module it originates from.
prettyModuleError :: (ModuleDefinition, ModuleError) -> Text
prettyModuleError (moduleDefinitionName -> moduleName, err) =
  [p|
    Error in module ‘#{pretty moduleName}’:
    #{message}
    |]
    where message :: Text
          message = case err of
            DuplicateRecordField record field ->
              [p| The record ‘#{pretty record}’ has multiple fields called ‘#{pretty field}’. |]
            DuplicateCaseName variant case_ ->
              [p| The variant ‘#{pretty variant}’ has multiple cases called ‘#{pretty case_}’ |]
            DuplicateCaseField variant case_ field ->
              [p| The case ‘#{pretty case_}’ of the variant ‘#{pretty variant}’ has multiple fields called ‘#{pretty field}’. |]
            UndefinedType name ->
              [p| The type ‘#{pretty name}’ is not defined. |]
            DuplicateTypeName name ->
              [p|
                The type ‘#{pretty name}’ has been defined multiple times.

                Fully qualified names have to be globally unique in Theta schemas.
                   |]

