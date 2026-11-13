defmodule CredoChecks.UseCoreModal do
  @moduledoc """
  Ensures that `<.modal>` (`CoreComponents.Modal.modal/1`) is used instead of hand-rolled modal overlay HTML.

  A `<div>` with `class="... fixed inset-0 ... justify-center ..."` is the canonical pattern
  for a custom modal backdrop. It should be replaced with `<.modal>` (or the
  `<.modal>` shorthand when imported), which provides consistent styling, keyboard handling,
  and accessibility across the application.

  ## Known gaps

  # TODO: the pattern is positional, so it catches the spelling this codebase
  #       actually writes and little else. Not flagged: the tokens in another
  #       order (`justify-center` before `fixed inset-0`, or `inset-0 fixed`);
  #       `top-0 left-0 right-0 bottom-0` written out instead of `inset-0`; and
  #       `place-items-center` instead of `justify-center`. The z-index is
  #       correctly irrelevant: any value matches, as does none. Hardening it
  #       means matching the tokens in any order within one attribute. Deferred
  #       rather than dropped: the current pattern has no false positives, and
  #       a hand-rolled backdrop is copied from the last hand-rolled backdrop,
  #       so the copies share a spelling. A `class` attribute the formatter has
  #       wrapped is caught: tags are read whole by `CredoChecks.HtmlTags`.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    exit_status: 0,
    explanations: [
      check: """
      Avoid hand-rolling modal overlay HTML. Use `TymeslotWeb.Components.CoreComponents.Modal.modal/1`
      instead.

      A div with `fixed inset-0` combined with `justify-center` is the telltale pattern for a
      custom modal backdrop. Replace it with:

          <.modal id="my-modal" show={@show} on_cancel={...}>
            <:header>Title</:header>
            Content here.
          </.modal>
      """,
      params: []
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile
  alias CredoChecks.HtmlTags

  # Matches any class string that contains both "fixed inset-0" and "justify-center",
  # which is the distinctive signature of a hand-rolled full-viewport modal backdrop.
  @backdrop_regex ~r/class=["\'][^"\']*fixed inset-0[^"\']*justify-center[^"\']*["\']/

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), any) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename

    if String.contains?(filename, "use_core_modal.ex") or
         String.contains?(filename, "core_components/") do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      for %{line_no: line_no, text: text} <- HtmlTags.tags(source_file, "[.:]?[a-z][\\w.:-]*"),
          Regex.match?(@backdrop_regex, text) do
        issue_for(issue_meta, line_no)
      end
    end
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message:
        "Avoid hand-rolled modal backdrops. Use `TymeslotWeb.Components.CoreComponents.Modal.modal/1` instead.",
      line_no: line_no,
      trigger: "fixed inset-0"
    )
  end
end
