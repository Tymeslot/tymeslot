defmodule CredoChecks.UseModalHook do
  @moduledoc """
  Flags modal visibility or payload set with a raw assign instead of
  `TymeslotWeb.Hooks.ModalHook`.

  `ModalHook` keeps a modal's flag (`show_<name>_modal`) and its payload
  (`<name>_modal_data`) together: `show_modal/3` sets both, `hide_modal/2`
  clears both, and `with_modal_data/3` turns a duplicate confirm into a no-op.
  A hand-written `assign(:show_x_modal, false)` chain sets the flag and the
  payload separately, so a close path that resets one and forgets the other
  leaves stale data for the next open to render. `CredoChecks.UseCoreModal`
  covers the markup side (`<.modal>` rather than a hand-rolled backdrop); this
  check covers the state side.

  Flagged, in `lib/` only and outside `ModalHook` itself, for any key spelt
  `show_<name>_modal`, `<name>_modal_data`, `<name>_modal_open` or
  `<name>_modal_visible`:

    * the key as an atom argument to `assign`, `assign_new` or `update`,
      local or module-qualified, piped or not;
    * the key in a keyword list anywhere (covers `assign(socket, k: v)`,
      `send_update(Comp, k: v)` and an initial-state list assigned later);
    * the key in a map literal passed to `assign`.

  Reading the assign (`@show_x_modal`, `socket.assigns.show_x_modal`) and
  matching on it in a function head are not flagged. Inline disclosure state
  (`show_password`, `show_details`, `show_webhook_form`) does not match the
  spelling and stays a plain assign.

  ## Known gaps

  # TODO: the check keys on spelling. A modal whose state is named otherwise
  #       (`refund_payment` doubling as the visibility flag, `confirming?`) is
  #       invisible to it, and so is a key built at runtime with
  #       `String.to_atom/1`. Naming the registry keys is the convention that
  #       makes the spelling reliable; a new modal that dodges it is a review
  #       finding, not something this check can see.

  ## Examples

      # Bad: flag and payload managed separately
      socket
      |> assign(:show_refund_modal, true)
      |> assign(:refund_modal_data, payment)

      # Good: register `refund` in ModalHook's registry, then
      ModalHook.show_modal(socket, :refund, payment)
      ModalHook.hide_modal(socket, :refund)
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Open and close modals through `TymeslotWeb.Hooks.ModalHook`
      (`mount_modal/2`, `show_modal/3`, `hide_modal/2`, `with_modal_data/3`)
      rather than assigning `show_*_modal` / `*_modal_data` by hand. Register
      a new modal name in ModalHook's `@modal_registry`.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @assign_funs [:assign, :assign_new, :update]
  @modal_key ~r/^(show_\w+_modal|\w+_modal_(data|open|visible))$/

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{filename: filename} = source_file, params) do
    if applies_to?(filename) do
      issue_meta = IssueMeta.for(source_file, params)

      # The accumulator carries the last line seen: keyword lists have no
      # metadata of their own, and the prewalk reaches the call or block
      # holding one just before the list itself.
      {_ast, {issues, _line}} =
        source_file
        |> SourceFile.ast()
        |> Macro.prewalk({[], nil}, &traverse(&1, &2, issue_meta))

      Enum.reverse(issues)
    else
      []
    end
  end

  defp applies_to?(filename) do
    Regex.match?(~r{(^|/)lib/}, filename) and
      not String.ends_with?(filename, "hooks/modal_hook.ex")
  end

  # `assign(socket, :key, v)`, `assign(:key, v)` in a pipe, and the
  # module-qualified forms; also a map literal passed as the assigns.
  defp traverse({fun, meta, args} = ast, {issues, line}, issue_meta)
       when fun in @assign_funs and is_list(args) do
    line = meta[:line] || line
    {ast, {assign_arg_issues(args, line, issue_meta) ++ issues, line}}
  end

  defp traverse({{:., _, [_module, fun]}, meta, args} = ast, {issues, line}, issue_meta)
       when fun in @assign_funs and is_list(args) do
    line = meta[:line] || line
    {ast, {assign_arg_issues(args, line, issue_meta) ++ issues, line}}
  end

  # A map literal's pairs are keyword-shaped, but a map is a read (a function
  # head match) unless it is passed to assign, which the clauses above report.
  # Walk on with only the values, so the list clause never sees the keys.
  defp traverse({:%{}, meta, pairs}, {issues, line}, _issue_meta) when is_list(pairs) do
    values =
      Enum.map(pairs, fn
        {_key, value} -> value
        other -> other
      end)

    {{:%{}, meta, values}, {issues, meta[:line] || line}}
  end

  defp traverse({_form, meta, _args} = ast, {issues, line}, _issue_meta) when is_list(meta) do
    {ast, {issues, meta[:line] || line}}
  end

  defp traverse(list, {issues, line}, issue_meta) when is_list(list) do
    {list, {keyword_issues(list, line, issue_meta) ++ issues, line}}
  end

  defp traverse(ast, acc, _issue_meta), do: {ast, acc}

  # Keyword arguments are left to the list clause, which sees every keyword
  # list, so each key is reported once.
  defp assign_arg_issues(args, line, issue_meta) do
    Enum.flat_map(args, fn
      key when is_atom(key) -> key_issue(key, line, issue_meta)
      {:%{}, _meta, pairs} -> pair_issues(pairs, line, issue_meta)
      _other -> []
    end)
  end

  defp keyword_issues(list, line, issue_meta) do
    if list != [] and Enum.all?(list, &match?({key, _} when is_atom(key), &1)) do
      pair_issues(list, line, issue_meta)
    else
      []
    end
  end

  defp pair_issues(pairs, line, issue_meta) do
    Enum.flat_map(pairs, fn
      {key, _value} when is_atom(key) -> key_issue(key, line, issue_meta)
      _other -> []
    end)
  end

  defp key_issue(key, line, issue_meta) do
    name = Atom.to_string(key)

    if Regex.match?(@modal_key, name) do
      [
        format_issue(issue_meta,
          message:
            "Set `#{name}` through `TymeslotWeb.Hooks.ModalHook` (`show_modal/3`, " <>
              "`hide_modal/2`, `mount_modal/2`), not a raw assign.",
          line_no: line,
          trigger: name
        )
      ]
    else
      []
    end
  end
end
