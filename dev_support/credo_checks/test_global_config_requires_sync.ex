defmodule CredoChecks.TestGlobalConfigRequiresSync do
  @moduledoc """
  Ensures a test module that mutates node-wide application environment declares
  `async: false`.

  `Application.put_env/3` and `Application.delete_env/2` write to the node, not
  to the calling process. ExUnit runs async modules concurrently, so a module
  that changes application env while `async: true` changes it for every test
  running beside it, and restores it underneath them on exit. The victim is
  never the module that did it: it is whichever unrelated test happened to read
  that key during the window, which is why this class of failure reproduces only
  in a full run and passes in isolation.

  `Tymeslot.ConfigTestHelpers.with_config/2,3` is the project's wrapper around
  the same write and counts the same.

  Two ways a module acquires the mutation, and the check looks for both:

    * **Directly** — it calls `with_config`, `Application.put_env` or
      `Application.delete_env` in its own body.
    * **Through a case template** — it does neither, but `use`s a template whose
      own `setup` does. `Tymeslot.HttpTransportCase` points `:http_client_module`
      at the real HTTP client this way, taking the Mox stub away from every
      concurrent test. Credo analyses one file at a time and cannot follow `use`,
      so the templates are enumerated in `Tymeslot.Test.GlobalConfigTemplates`.

  The second is the one that matters most, because the offending module's own
  source looks completely inert.

  ## Opting out

  A key nothing else reads cannot cause interference, and serialising its module
  buys nothing. Mark such a module with a comment on the line above the `use`:

      # credo:global-config-safe — <why no concurrent reader exists>

  State the reason. "Nothing else reads this key" is checkable by the next
  person; a bare opt-out is not.

  ## Examples

      # Bad — writes application env while running concurrently
      defmodule MyApp.BillingTest do
        use MyApp.DataCase, async: true

        setup do
          with_config(:tymeslot, :stripe_provider, StubProvider)
        end
      end

      # Bad — inherits the mutation from the template, and looks inert doing it
      defmodule MyApp.ExchangeClientTest do
        use Tymeslot.ExchangeCase, async: true
      end

      # Good — serialised, so the write cannot reach a concurrent test
      defmodule MyApp.BillingTest do
        use MyApp.DataCase, async: false

        setup do
          with_config(:tymeslot, :stripe_provider, StubProvider)
        end
      end

      # Good — opted out, with the reason recorded
      defmodule MyApp.ExtensionSchemaTest do
        # credo:global-config-safe — :test_extensions has no reader in lib/
        use MyApp.DataCase, async: true

        setup do
          with_config(:tymeslot, :test_extensions, [])
        end
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      A test module that mutates node-wide application environment must declare
      async: false.

      Application.put_env/3 writes to the node, not the process, so an async
      module doing it reconfigures every test running alongside it. The failure
      surfaces in an unrelated module and only in a full run.

      Mutation is inherited through case templates too; those are listed in
      Tymeslot.Test.GlobalConfigTemplates.

      Opt out with `# credo:global-config-safe — <reason>` above the `use` when
      no concurrent reader of the key exists.
      """,
      params: [
        templates:
          "Override the case templates treated as mutating global config. " <>
            "Defaults to Tymeslot.Test.GlobalConfigTemplates.all/0."
      ]
    ]

  alias Credo.Code
  alias Credo.IssueMeta
  alias Tymeslot.Test.GlobalConfigTemplates

  @opt_out "credo:global-config-safe"

  @doc false
  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: list()
  def run(%Credo.SourceFile{} = source_file, params) do
    if test_file?(source_file.filename) and not opted_out?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)
      templates = Keyword.get(params, :templates, GlobalConfigTemplates.all())

      Code.prewalk(source_file, &traverse(&1, &2, issue_meta, templates))
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Read from the raw source rather than the AST: Elixir discards comments when
  # parsing, so an opt-out marker exists nowhere in the quoted form.
  defp opted_out?(source_file) do
    source_file |> Code.to_lines() |> Enum.any?(fn {_no, line} -> line =~ @opt_out end)
  end

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

  defp traverse(
         {:defmodule, meta, [name, [do: {:__block__, _meta, body}]]} = ast,
         issues,
         issue_meta,
         templates
       ) do
    check_module(ast, name, meta[:line], body, issues, issue_meta, templates)
  end

  defp traverse(
         {:defmodule, meta, [name, [do: single_expr]]} = ast,
         issues,
         issue_meta,
         templates
       )
       when not is_list(single_expr) do
    check_module(ast, name, meta[:line], [single_expr], issues, issue_meta, templates)
  end

  defp traverse(ast, issues, _issue_meta, _templates), do: {ast, issues}

  defp check_module(ast, name, line_no, body, issues, issue_meta, templates) do
    with true <- test_module?(name),
         true <- async?(body),
         {:ok, reason} <- mutates_global_config(body, templates) do
      {ast, [build_issue(issue_meta, line_no, reason) | issues]}
    else
      _no_issue -> {ast, issues}
    end
  end

  # Only modules whose last name segment ends in "Test": inline helper and mock
  # modules defined inside a test file are not test modules.
  defp test_module?({:__aliases__, _, segments}) when is_list(segments) do
    case List.last(segments) do
      name when is_atom(name) -> name |> to_string() |> String.ends_with?("Test")
      _other -> false
    end
  end

  defp test_module?(_name), do: false

  # A module is concurrent only if it says so. `async:` defaults to false in
  # every case template here, so an absent option is not a finding.
  defp async?(body) do
    Enum.any?(body, fn
      {:use, _meta, [_template, opts]} when is_list(opts) -> Keyword.get(opts, :async) == true
      _other -> false
    end)
  end

  defp mutates_global_config(body, templates) do
    cond do
      template = used_template(body, templates) -> {:ok, {:template, template}}
      call = direct_call(body) -> {:ok, {:direct, call}}
      true -> :none
    end
  end

  defp used_template(body, templates) do
    Enum.find_value(body, fn
      {:use, _meta, [{:__aliases__, _alias_meta, segments} | _opts]} ->
        module = Module.concat(segments)
        if module in templates, do: module

      _other ->
        nil
    end)
  end

  # Walks the whole module body: the write is usually inside a `setup` or a
  # single test, never at the top level.
  defp direct_call(body) do
    {_ast, found} =
      Macro.prewalk(body, nil, fn
        {:with_config, _meta, args} = node, nil when is_list(args) ->
          {node, "with_config"}

        {{:., _dot, [{:__aliases__, _am, [:Application]}, fun]}, _meta, _args} = node, nil
        when fun in [:put_env, :delete_env] ->
          {node, "Application.#{fun}"}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp build_issue(issue_meta, line_no, {:template, template}) do
    format_issue(issue_meta,
      message:
        "Test module is async: true but uses #{inspect(template)}, whose setup writes " <>
          "node-wide application env — it will reconfigure every test running beside it. " <>
          "Declare async: false, or opt out with `# credo:global-config-safe — <reason>`.",
      line_no: line_no,
      trigger: "async: true"
    )
  end

  defp build_issue(issue_meta, line_no, {:direct, call}) do
    format_issue(issue_meta,
      message:
        "Test module is async: true and calls #{call}, which writes node-wide application " <>
          "env — it will reconfigure every test running beside it. Declare async: false, " <>
          "or opt out with `# credo:global-config-safe — <reason>`.",
      line_no: line_no,
      trigger: "async: true"
    )
  end
end
