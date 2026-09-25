defmodule CredoChecks.MoxExpectRequiresVerify do
  @moduledoc """
  Flags a test file that calls `Mox.expect/3,4` but never calls `verify_on_exit!`.

  `expect/3,4` sets a call-count expectation: the mock must be called exactly
  that many times. Nothing checks that on its own. Without `ExUnit.Callbacks.
  verify_on_exit!/1` registered as an `on_exit` callback, Mox never asserts the
  expectation was met, so a call that quietly stops happening (a refactor that
  drops the code path calling it) leaves the test green while asserting
  nothing. The test looks like it verifies the interaction; it does not.

  `verify_on_exit!` is opt-in per file in this project, not inherited from a
  shared case template. The case templates a test could plausibly build on —
  `Tymeslot.DataCase`, `TymeslotWeb.ConnCase`, `TymeslotWeb.LiveCase`,
  `Tymeslot.MockCase`, and the helpers `Tymeslot.TestHelpers` and
  `Tymeslot.TestMocks` pull in — were checked and **none of them call
  `verify_on_exit!`** in their own `setup`; each only mentions it in a
  `@moduledoc` usage example. That is why `verifying_templates` (see below)
  defaults to an empty list: today, every test file that uses `expect/3,4`
  against a `*Mock` module must call `verify_on_exit!` itself.

  ## Expectations set on a file's behalf

  A test file need not call `expect/3,4` itself to own an unverified
  expectation. `Tymeslot.WorkerTestHelpers.expect_http_success/2` and its
  siblings set one inside a support module, and the file that calls them is
  where `verify_on_exit!` has to go. Credo reads one file at a time and cannot
  follow the call, so those helpers are enumerated in the `expect_helpers`
  param and a call to one counts exactly as an inline `expect/3,4` would.

  Support files themselves stay out of scope: the helper is not the place the
  expectation is verified, so flagging it would ask for `verify_on_exit!` in a
  module that has no test to attach it to.

  ## What to do instead

  Add `setup :verify_on_exit!` (or `setup do verify_on_exit!() end`) to the
  test module, or switch the call to `Mox.stub/3` if the call count genuinely
  does not matter and only a canned return value is needed. An explicit
  `Mox.verify!/0,1` counts too, though `verify_on_exit!` is preferred: it
  still runs when the test fails part-way, and an inline `verify!` does not.

  ## Configuration

  If a future case template's `setup` calls `verify_on_exit!` on behalf of
  every test using it, register it so this check stops asking those files to
  call it again:

      {CredoChecks.MoxExpectRequiresVerify, verifying_templates: [MyApp.SomeVerifyingCase]}

  A support helper that sets an expectation on its callers' behalf is
  registered the same way, as `{Module, [function names]}`:

      {CredoChecks.MoxExpectRequiresVerify,
       expect_helpers: [{MyApp.WorkerTestHelpers, [:expect_http_success]}]}

  ## Examples

      # Bad — the expectation is never checked
      defmodule MyApp.BookingTest do
        use MyApp.DataCase, async: true

        test "sends a confirmation" do
          expect(MyApp.EmailServiceMock, :send_confirmation, fn _ -> {:ok, :sent} end)
          BookingFlow.confirm(booking())
        end
      end

      # Good — verify_on_exit! makes the expectation actually count
      defmodule MyApp.BookingTest do
        use MyApp.DataCase, async: true

        setup :verify_on_exit!

        test "sends a confirmation" do
          expect(MyApp.EmailServiceMock, :send_confirmation, fn _ -> {:ok, :sent} end)
          BookingFlow.confirm(booking())
        end
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      verifying_templates: [],
      expect_helpers: [
        {Tymeslot.WorkerTestHelpers,
         [
           :expect_calendar_create_success,
           :expect_calendar_delete_success,
           :expect_calendar_update_success,
           :expect_http_success,
           :expect_zoom_success
         ]},
        {Tymeslot.AuthTestHelpers, [:setup_oauth_authorize_url]}
      ]
    ],
    explanations: [
      check: """
      Mox.expect/3,4 sets a call-count expectation that only verify_on_exit!
      checks. Without it, a mocked call that silently stops happening leaves
      the test green while asserting nothing.

      Add `setup :verify_on_exit!` to the test module, or use `Mox.stub/3`
      instead if the call count does not matter.
      """,
      params: [
        verifying_templates:
          "Case templates whose own setup calls verify_on_exit! on behalf of " <>
            "every test using them. A test module using one of these is not " <>
            "flagged even without calling verify_on_exit! itself. Empty by " <>
            "default: no case template in this project currently does this.",
        expect_helpers:
          "Support-module functions that set a Mox expectation on their " <>
            "caller's behalf, as {Module, [function names]}. A test file " <>
            "calling one owns the expectation and must verify it, exactly as " <>
            "if it had called expect/3,4 inline."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  # Both halves of Mox's verification API. verify_on_exit!/0,1 registers an
  # on_exit callback; verify!/0,1 checks inline, there and then.
  @verify_functions [:verify_on_exit!, :verify!]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    if test_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      templates = Params.get(params, :verifying_templates, __MODULE__)
      helpers = params |> Params.get(:expect_helpers, __MODULE__) |> index_helpers()

      state =
        Code.prewalk(
          source_file,
          &traverse(&1, &2, templates, helpers),
          %{offending_line: nil, verified?: false, imported: MapSet.new()}
        )

      if state.offending_line && not state.verified? do
        [build_issue(issue_meta, state.offending_line)]
      else
        []
      end
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Helper index
  # ---------------------------------------------------------------------------

  # Built once per file rather than per call node. A qualified call is matched
  # on its last alias segment, so that `WorkerTestHelpers.f()` and the fully
  # qualified `Tymeslot.WorkerTestHelpers.f()` both resolve; a bare call is
  # matched on the full module, which is what an `import` names.
  defp index_helpers(helpers) do
    %{
      by_alias:
        Map.new(helpers, fn {module, funs} ->
          {module |> Module.split() |> List.last() |> String.to_atom(), MapSet.new(funs)}
        end),
      by_module: Map.new(helpers, fn {module, funs} -> {module, MapSet.new(funs)} end)
    }
  end

  # ---------------------------------------------------------------------------
  # File scope
  # ---------------------------------------------------------------------------

  # Credo reports repo-relative filenames, so match on the path segment rather
  # than searching for "/test/" in the string.
  defp test_file?(filename) do
    segments = Path.split(filename)

    String.ends_with?(filename, "_test.exs") and
      "test" in segments and
      not support_file?(segments)
  end

  defp support_file?(segments) do
    segments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 == ["test", "support"]))
  end

  # ---------------------------------------------------------------------------
  # Traversal
  # ---------------------------------------------------------------------------

  # `setup :verify_on_exit!`
  defp traverse({:setup, _meta, [:verify_on_exit!]} = ast, acc, _templates, _helpers) do
    {ast, %{acc | verified?: true}}
  end

  # A direct call: `verify_on_exit!()`, whether at the top of the module or
  # inside a `setup do ... end` block. `verify!/0,1` called inline counts too:
  # it is the other half of Mox's verification API, and a file using it is
  # checking its expectations, not ignoring them.
  defp traverse({name, _meta, _args} = ast, acc, _templates, _helpers)
       when name in @verify_functions do
    {ast, %{acc | verified?: true}}
  end

  # The fully-qualified forms, `Mox.verify_on_exit!()` and `Mox.verify!()`.
  defp traverse(
         {{:., _dot_meta, [{:__aliases__, _am, [:Mox]}, name]}, _meta, _args} = ast,
         acc,
         _templates,
         _helpers
       )
       when name in @verify_functions do
    {ast, %{acc | verified?: true}}
  end

  # A `use` of a case template whose own setup calls verify_on_exit! for us.
  defp traverse(
         {:use, _meta, [{:__aliases__, _am, segments} | _opts]} = ast,
         acc,
         templates,
         _helpers
       ) do
    if Module.concat(segments) in templates do
      {ast, %{acc | verified?: true}}
    else
      {ast, acc}
    end
  end

  # `import Tymeslot.WorkerTestHelpers` makes its expect-setting functions
  # callable unqualified, so remember it and match bare calls against it below.
  # Prewalk is top-down and an import precedes the calls it enables, so the
  # import is always seen first.
  defp traverse(
         {:import, _meta, [{:__aliases__, _am, segments} | _opts]} = ast,
         acc,
         _templates,
         helpers
       ) do
    module = Module.concat(segments)

    if Map.has_key?(helpers.by_module, module) do
      {ast, %{acc | imported: MapSet.put(acc.imported, module)}}
    else
      {ast, acc}
    end
  end

  defp traverse(ast, acc, _templates, helpers) do
    case mox_expect_line(ast) || helper_expect_line(ast, acc, helpers) do
      nil -> {ast, acc}
      line -> {ast, record_offense(acc, line)}
    end
  end

  # ---------------------------------------------------------------------------
  # Expectations set by a support helper
  # ---------------------------------------------------------------------------

  # Qualified: `WorkerTestHelpers.expect_http_success(...)`. Matched on the last
  # alias segment so that both the aliased and fully-qualified spellings hit.
  defp helper_expect_line(
         {{:., _dot_meta, [{:__aliases__, _am, segments}, fun]}, meta, args},
         _acc,
         helpers
       )
       when is_list(args) do
    funs = Map.get(helpers.by_alias, List.last(segments), MapSet.new())

    if fun in funs, do: meta[:line]
  end

  # Bare: `expect_http_success(...)`, reachable only through an import the file
  # has already made.
  defp helper_expect_line({fun, meta, args}, acc, helpers) when is_atom(fun) and is_list(args) do
    if Enum.any?(acc.imported, &(fun in Map.fetch!(helpers.by_module, &1))) do
      meta[:line]
    end
  end

  defp helper_expect_line(_other, _acc, _helpers), do: nil

  defp record_offense(%{offending_line: nil} = acc, line), do: %{acc | offending_line: line}
  defp record_offense(acc, _line), do: acc

  # `Mox.expect(CalendarMock, ...)`
  defp mox_expect_line({{:., _dot_meta, [{:__aliases__, _am, [:Mox]}, :expect]}, meta, args})
       when is_list(args) do
    mock_first_arg_line(args, meta)
  end

  # Bare `expect(CalendarMock, ...)`, imported from Mox.
  defp mox_expect_line({:expect, meta, args}) when is_list(args) do
    mock_first_arg_line(args, meta)
  end

  defp mox_expect_line(_other), do: nil

  # The first argument identifies which mock is being set up; requiring it to
  # be a `*Mock` alias is what keeps `:meck.expect(SomeModule, ...)` out of
  # scope — that call is always qualified with the `:meck` atom and never
  # takes a `*Mock` alias as its first argument.
  defp mock_first_arg_line([{:__aliases__, _am, segments} | _rest], meta)
       when is_list(segments) do
    if segments |> List.last() |> to_string() |> String.ends_with?("Mock") do
      meta[:line]
    end
  end

  defp mock_first_arg_line(_args, _meta), do: nil

  # ---------------------------------------------------------------------------
  # Issues
  # ---------------------------------------------------------------------------

  defp build_issue(issue_meta, line_no) do
    format_issue(issue_meta,
      message:
        "This file calls Mox.expect/3,4 against a *Mock module but never calls " <>
          "verify_on_exit!, so the expectation is never checked. Add " <>
          "`setup :verify_on_exit!`, or use `Mox.stub/3` if the call count " <>
          "does not matter.",
      line_no: line_no,
      trigger: "expect"
    )
  end
end
