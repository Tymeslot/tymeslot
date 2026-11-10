defmodule CredoChecks.NoBrowserValidation do
  @moduledoc """
  Ensures every form leaves validation to the server's inline errors.

  Without `novalidate` the browser blocks a submit and shows its own bubble, in
  the browser's language rather than the user's Tymeslot locale, before the
  inline error can appear. Constraint attributes stay on the input for
  accessibility; `novalidate` stops the browser enforcing them.

  `<form>` and `<.form>` must carry `novalidate`. `<.form_wrapper>` and
  `<.auth_form>` default to it, so they are flagged only if they opt out with
  `novalidate={false}`. A form that can never carry a constraint still sets it,
  so the rule has no judgement call in it.

  A form may opt out by listing its file in the `allowed_files` param in
  `.credo.exs`, with the reason beside it. The tag is read whole, across lines
  (see `CredoChecks.HtmlTags`), so an alias-qualified `<Forms.form_wrapper>`
  counts too, and documentation heredocs are skipped.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed_files: []],
    explanations: [
      check: """
      Set `novalidate` on the form and render an inline error for every
      constraint the form carries.

          <.form for={@form} phx-submit="save" novalidate>

      Without it the browser shows its own validation bubble instead of the
      inline error. List the file in `allowed_files` in `.credo.exs`, with the
      reason, only when the form has no inline error to fall back on.
      """,
      params: [allowed_files: "Path suffixes of files whose forms may omit `novalidate`."]
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile
  alias CredoChecks.HtmlTags

  # `form`, `.form`, and the same names qualified by a module alias, such as
  # `Phoenix.Component.form` or `Forms.form_wrapper`.
  @tag_pattern ~S"form|(?:[A-Z][\w.]*)?\.(?:form|form_wrapper|auth_form)"
  @opted_out ~r/\snovalidate=\{\s*false\s*\}/i
  @carries ~r/\snovalidate(?:[\s=\/>]|$)/i

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    allowed = Params.get(params, :allowed_files, __MODULE__)

    if String.ends_with?(filename, "_test.exs") or
         String.contains?(filename, "controllers/dev/") or
         Enum.any?(allowed, &String.ends_with?(filename, &1)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      for %{name: name, line_no: line_no, text: text} <-
            HtmlTags.tags(source_file, @tag_pattern),
          flagged?(name, text) do
        format_issue(issue_meta,
          message:
            "`<#{name}>` must set `novalidate` and rely on inline errors. See `CredoChecks.NoBrowserValidation`.",
          line_no: line_no,
          trigger: "<#{name}"
        )
      end
    end
  end

  defp flagged?(name, text) do
    opted_out? = Regex.match?(@opted_out, text)
    carries? = Regex.match?(@carries, text)
    component = name |> String.split(".") |> List.last()

    opted_out? or (component == "form" and not carries?)
  end
end
