defmodule CredoChecks.UseCoreModal do
  @moduledoc """
  Ensures that `CoreComponents.modal` is used instead of hand-rolled modal overlay HTML.

  A `<div>` with `class="... fixed inset-0 ... justify-center ..."` is the canonical pattern
  for a custom modal backdrop. It should be replaced with `<CoreComponents.modal>` (or the
  `<.modal>` shorthand when imported), which provides consistent styling, keyboard handling,
  and accessibility across the application.

  ## Known gaps

  # TODO: the pattern is positional and line-based, so it catches the spelling this
  #       codebase actually writes and little else. Not flagged: the tokens in another
  #       order (`justify-center` before `fixed inset-0`, or `inset-0 fixed`);
  #       `top-0 left-0 right-0 bottom-0` written out instead of `inset-0`;
  #       `place-items-center` instead of `justify-center`; and a `class` attribute the
  #       formatter has wrapped across two lines, since the check reads the file line by
  #       line. The z-index is correctly irrelevant: any value matches, as does none.
  #       Hardening it means matching the tokens in any order within one attribute and
  #       joining wrapped attributes before the match. Deferred rather than dropped: the
  #       current pattern has no false positives, and a hand-rolled backdrop is copied
  #       from the last hand-rolled backdrop, so the copies share a spelling.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    exit_status: 0,
    explanations: [
      check: """
      Avoid hand-rolling modal overlay HTML. Use `TymeslotWeb.Components.CoreComponents.modal/1`
      instead.

      A div with `fixed inset-0` combined with `justify-center` is the telltale pattern for a
      custom modal backdrop. Replace it with:

          <CoreComponents.modal id="my-modal" show={@show} on_cancel={...}>
            <:header>Title</:header>
            Content here.
          </CoreComponents.modal>
      """,
      params: []
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

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

      source_file
      |> SourceFile.lines()
      |> Enum.reduce([], fn {line_no, line}, issues ->
        if Regex.run(@backdrop_regex, line) do
          [issue_for(issue_meta, line_no) | issues]
        else
          issues
        end
      end)
    end
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message:
        "Avoid hand-rolled modal backdrops. Use `TymeslotWeb.Components.CoreComponents.modal/1` instead.",
      line_no: line_no,
      trigger: "fixed inset-0"
    )
  end
end
