defmodule CredoChecks.Phoenix.RequireComponentAttrs do
  @moduledoc """
  Ensures that Phoenix function components declare their attributes using `attr/3`.

  Function components that accept assigns should declare their expected attributes
  using the `attr/3` macro. This provides:
  - Compile-time validation of missing or incorrect attributes
  - Self-documenting component APIs
  - Better editor tooling support

  ## Examples

  Bad:

      def my_component(assigns) do
        ~H\"""
        <div>{@title}</div>
        \"""
      end

  Good:

      attr :title, :string, required: true

      def my_component(assigns) do
        ~H\"""
        <div>{@title}</div>
        \"""
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    exit_status: 0,
    explanations: [
      check: """
      Function components should declare their attributes using `attr/3`.

      This provides compile-time validation and documents the component's interface.
      """,
      params: []
    ]

  alias Credo.Code
  alias Credo.IssueMeta

  @doc false
  @impl true
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    # Skip test files, non-component files, and email components
    if should_skip_file?(source_file.filename) do
      []
    else
      Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # Skip files that shouldn't be checked
  defp should_skip_file?(filename) do
    String.contains?(filename, "_test.exs") or
      String.contains?(filename, "/test/") or
      String.contains?(filename, "/emails/") or
      String.contains?(filename, "live_view.ex") or
      String.contains?(filename, "live_component.ex") or
      String.ends_with?(filename, "_live.ex")
  end

  # Main traversal - look for defmodule nodes
  defp traverse({:defmodule, _meta, [_alias, [do: {:__block__, _, body}]]} = ast, issues, issue_meta) do
    if uses_phoenix_component?(body) do
      new_issues = check_functions_in_module(body, issue_meta)
      {ast, issues ++ new_issues}
    else
      {ast, issues}
    end
  end

  # Handle single-expression modules
  defp traverse({:defmodule, _meta, [_alias, [do: body]]} = ast, issues, issue_meta) when not is_list(body) do
    if uses_phoenix_component?([body]) do
      new_issues = check_functions_in_module([body], issue_meta)
      {ast, issues ++ new_issues}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  # Check if module uses Phoenix.Component
  defp uses_phoenix_component?(body) when is_list(body) do
    Enum.any?(body, fn
      {:use, _, [{:__aliases__, _, [:Phoenix, :Component]} | _]} -> true
      _other -> false
    end)
  end

  # Check all functions in the module body
  defp check_functions_in_module(body, issue_meta) when is_list(body) do
    body
    |> Enum.with_index()
    |> Enum.reduce([], fn {node, index}, acc ->
      case node do
        {:def, meta, [{func_name, _, [{:assigns, _, nil}]}, func_body]} ->
          # Found a function component - check if it uses any assigns
          uses_assigns = component_uses_assigns?(func_body)

          # Skip if component doesn't use assigns (static HTML only)
          if not uses_assigns do
            acc
          # Check if it has attr declarations before it
          else if has_attr_before?(body, index) do
            acc
          else
            [create_issue(issue_meta, meta, func_name) | acc]
          end
          end

        _other ->
          acc
      end
    end)
  end

  # Check if a component function body uses any assigns (@variable syntax)
  defp component_uses_assigns?(func_body) do
    {_, uses_assigns} =
      Macro.prewalk(func_body, false, fn
        # Look for @variable references (module attributes used as assigns)
        {:@, _, [{var_name, _, _}]} = node, _acc
        when is_atom(var_name) and var_name not in [:moduledoc, :doc, :spec, :impl, :behaviour, :type, :typep, :opaque, :callback, :macrocallback] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    uses_assigns
  end

  # Check if there are any attr/3 calls before the given index
  defp has_attr_before?(body, func_index) when func_index > 0 do
    # Look backwards from the function for attr declarations
    # Stop when we hit another def/defp or use statement
    body
    |> Enum.slice(0, func_index)
    |> Enum.reverse()
    |> Enum.reduce_while(false, fn node, _acc ->
      case node do
        # Found an attr - success!
        {:attr, _, _} ->
          {:halt, true}

        # Found another function - stop searching
        {:def, _, _} ->
          {:halt, false}

        {:defp, _, _} ->
          {:halt, false}

        # Module attribute or doc - keep searching
        {:@, _, _} ->
          {:cont, false}

        # Use statement - stop searching
        {:use, _, _} ->
          {:halt, false}

        # Anything else - keep searching
        _other ->
          {:cont, false}
      end
    end)
  end

  defp has_attr_before?(_body, _func_index), do: false

  # Create an issue for a function without attr declarations
  defp create_issue(issue_meta, meta, func_name) do
    line_no = meta[:line] || 0

    format_issue(
      issue_meta,
      message:
        "Function component `#{func_name}/1` should declare its attributes using `attr/3`",
      line_no: line_no,
      trigger: "def #{func_name}"
    )
  end
end
