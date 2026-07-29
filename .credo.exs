# Credo configuration for the Tymeslot Core repository.
#
# This is the canonical config for the standalone Core repo: the custom checks
# live under dev_support/credo_checks/ and are loaded via `requires` below.
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
        "dev_support/credo_checks/**/*.ex"
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
          # Suggest ~p/url(~p) in appropriate contexts (conservative by default)
          {CredoChecks.Phoenix.UsePSigil, [priority: :low, mode: :moderate, ignore_tests?: true]},
          {CredoChecks.UseCoreInputs, []},
          {CredoChecks.UseCoreModal, []},
          {CredoChecks.UseColorScale, [priority: :low]},
          {CredoChecks.NoArbitraryHexColors, [priority: :low]},
          {CredoChecks.RequireDashboardSectionHeader, [priority: :low]},
          {CredoChecks.Phoenix.RequireComponentAttrs, [priority: :high]},
          {CredoChecks.TestModuleTagRequired, [priority: :high]},
          # Logger hygiene: violations are :low while being cleared; raise to :high after Phase 3-4
          {CredoChecks.NoStringInterpolationInLogger, [priority: :high]},
          {CredoChecks.NoMapMetadataInLogger, [priority: :high]},
          {CredoChecks.MigrationConstraintSafety, [priority: :high, enforce_after: "20260329"]},
          {CredoChecks.RepoCallBoundary, [priority: :normal]},
          {CredoChecks.ClockUsage, [priority: :normal]},
          {CredoChecks.GettextDomainBoundary, [priority: :high]},
          {CredoChecks.NoUnsafeSanitizeMerge, [priority: :normal]},
          # The three below mechanise rules that CLAUDE.md's prefer/avoid table
          # already states in prose. Ported from ex_slop and oeditus_credo
          # (both MIT) rather than taking the dependencies, so each is scoped
          # to this codebase's conventions and lives beside the other checks.
          #
          # The first run found 105 dual-key reads, 56 silent rescues and 8
          # boolean cases: a backlog worked through deliberately, rather than
          # fixed under a red gate. (NoSwallowedException's count dropped
          # from its original 116 once the heuristic learned that passing
          # the rescued exception on to a helper counts as handling it, not
          # swallowing it; the residual count was genuine silent rescues.)
          # All three have now reached zero and are gated.
          {CredoChecks.NoDualKeyAccess, [priority: :normal]},
          {CredoChecks.NoCaseOnBoolean, [priority: :low]},
          {CredoChecks.NoSwallowedException, [priority: :normal]},
          {CredoChecks.NoInlineCaldavList, [priority: :normal]},
          {CredoChecks.AttendeeNotificationsBoundary, []},

          #
          ## Test Quality Checks (jump_credo_checks)
          #
          # A suite stays green whether or not its tests assert anything, so
          # these are the checks least likely to be noticed missing.
          #
          # exit_status: 0 means they report without failing the build. The
          # first run found 1000 findings across 283 files, which is a backlog
          # to work through deliberately, not something to fix under a red
          # gate. Drop exit_status per check as each one reaches zero; that
          # ratchet is the point, and a check left reporting forever is just
          # noise nobody reads.
          #
          # UnusedLiveViewAssign and AvoidSocketAssignsInTest are deliberately
          # absent: both are structurally wrong for this codebase rather than
          # merely noisy. UnusedLiveViewAssign only looks within one module,
          # so it cannot see an assign written by a component and read by its
          # sibling event-handler module, nor one consumed by root.html.heex;
          # 70 of its 77 findings were that. AvoidSocketAssignsInTest wants
          # user-observable output, but 201 of its 218 findings were in unit
          # tests of socket-transformer functions, where socket.assigns is
          # the return value and there is no rendered output to assert on.
          {Jump.CredoChecks.VacuousTest, [priority: :low, exit_status: 0]},
          {Jump.CredoChecks.TestHasNoAssertions, [priority: :low, exit_status: 0]},
          {Jump.CredoChecks.WeakAssertion, [priority: :low, exit_status: 0]},
          {Jump.CredoChecks.ConditionalAssertion, [priority: :low, exit_status: 0]},
          {Jump.CredoChecks.AssertElementSelectorCanNeverFail, [priority: :low, exit_status: 0]},

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
          # Disabled: we intentionally use inline Logger.info(msg, key: val) for domain-specific
          # data instead of global metadata. Global metadata is kept minimal (request_id, user_id, etc).
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
