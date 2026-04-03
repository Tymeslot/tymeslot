# This file contains the configuration for Credo for the Tymeslot core application.
# This config is specific to the core app and runs when executing credo from apps/tymeslot/
#
# For umbrella-level analysis, use the root .credo.exs which scans all apps.

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "test/",
          "dev_support/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/", ~r"/dev_support/credo_checks/"]
      },
      plugins: [],
      requires: [
        # Tag taxonomy must be loaded first so the check can call TagTaxonomy.all()
        "test/support/tag_taxonomy.ex",
        "dev_support/credo_checks/empty_files.ex",
        "dev_support/credo_checks/large_modules.ex",
        "dev_support/credo_checks/no_map_metadata_in_logger.ex",
        "dev_support/credo_checks/no_string_interpolation_in_logger.ex",
        "dev_support/credo_checks/require_dashboard_section_header.ex",
        "dev_support/credo_checks/thin_wrapper_functions.ex",
        "dev_support/credo_checks/use_core_inputs.ex",
        "dev_support/credo_checks/use_core_modal.ex",
        "dev_support/credo_checks/use_p_sigil.ex",
        "dev_support/credo_checks/test_module_tag_required.ex",
        "dev_support/credo_checks/migration_constraint_safety.ex"
      ],
      strict: false,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          #
          ## Consistency Checks
          #
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          #
          ## Design Checks
          #
          {Credo.Check.Design.AliasUsage,
           [priority: :normal, if_nested_deeper_than: 1, if_called_more_often_than: 0]},
          {Credo.Check.Design.TagFIXME, []},
          {Credo.Check.Design.TagTODO, [exit_status: 2]},
          {Credo.Check.Design.DuplicatedCode, [nodes_threshold: 2, mass_threshold: 40]},

          #
          ## Readability Checks
          #
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},

          #
          ## Refactoring Opportunities
          #
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15]},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 4]},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},

          #
          ## Custom Project Checks (low priority, only visible with --strict)
          #
          {CredoChecks.ThinWrapperFunctions, [priority: :low]},
          {CredoChecks.EmptyFiles, [priority: :low]},
          {CredoChecks.LargeModules, [priority: :low]},
          {CredoChecks.Phoenix.UsePSigil, [priority: :low, mode: :moderate, ignore_tests?: true]},
          {CredoChecks.UseCoreInputs, []},
          {CredoChecks.UseCoreModal, []},
          {CredoChecks.RequireDashboardSectionHeader, [priority: :low]},
          {CredoChecks.TestModuleTagRequired, [priority: :high]},
          # Logger hygiene: violations are :low while being cleared; raise to :high after Phase 3-4
          {CredoChecks.NoStringInterpolationInLogger, [priority: :high]},
          {CredoChecks.NoMapMetadataInLogger, [priority: :high]},
          {CredoChecks.MigrationConstraintSafety, [priority: :high, enforce_after: "20260329"]},

          #
          ## Additional Maintainability Checks (low priority, only visible with --strict)
          #
          {Credo.Check.Refactor.ABCSize, [priority: :low, max_size: 50]},
          {Credo.Check.Readability.Specs, [priority: :low]},
          {Credo.Check.Readability.BlockPipe, [priority: :low]},
          {Credo.Check.Readability.SinglePipe, [priority: :low]},
          {Credo.Check.Warning.LeakyEnvironment, [priority: :low]},

          #
          ## Warnings
          #
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          # Disabled: inline Logger.info(msg, key: val) is the project standard; domain-specific
          # keys are passed at call sites, not registered in the formatter metadata list.
          # {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []},
          {Credo.Check.Warning.UnsafeToAtom, []},

          #
          # Newly enabled checks for code quality
          #
          {Credo.Check.Refactor.UtcNowTruncate, []},
          {Credo.Check.Consistency.UnusedVariableNames, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []}
        ],
        disabled: [
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.RejectFilter, []}
        ]
      }
    }
  ]
}
