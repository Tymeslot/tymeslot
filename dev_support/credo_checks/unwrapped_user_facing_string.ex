defmodule CredoChecks.UnwrappedUserFacingString do
  @moduledoc """
  Flags user-facing string literals that were never wrapped in gettext.

  The `GettextDomainBoundary` check validates the *domain* of strings that
  already call `dgettext`, but it cannot see a user-facing string that was
  never wrapped at all. This check closes that gap for the two highest-signal,
  lowest-noise positions where an un-translated literal is almost always a real
  bug:

  1. **Flash messages** — the message argument of `put_flash/2,3` (both the
     direct `put_flash(conn, :error, "…")` and the piped
     `socket |> put_flash(:error, "…")` forms) and of the project's
     `Flash.error/info/warning/success("…")` helper. A bare string literal here
     ships untranslated to the user. The codebase already routes these through
     helper functions or `dgettext`; a raw literal is the exact gap that slipped
     past the first localisation pass (e.g. an entire controller-helper module
     that never declared `use Gettext`).

  2. **Phoenix `attr` defaults** — a prose `default:` on a component attribute,
     e.g. `attr :confirm_text, :string, default: "Processing…"`. Because an
     `attr` default must be a compile-time constant it cannot itself hold a
     `dgettext` call, so a prose default is a leak by construction; the fix is
     `default: nil` plus a render-time `{@x || dgettext(...)}` fallback.

  Only *prose* is flagged (a value containing whitespace between words, or
  ending in sentence punctuation / an ellipsis). Single-token values such as
  `"column"`, `"Default"`, atoms-as-strings, CSS classes, and identifiers are
  left alone — they are usually technical, and gating them would be too noisy.
  HEEx text nodes and attribute literals are deliberately out of scope: parsing
  them from the `~H` sigil is heuristic and noisy, so they belong in a manual
  sweep rather than a build-blocking check.

  ## Examples

      # Bad — untranslated flash literal
      put_flash(conn, :error, "Please try again.")
      socket |> put_flash(:info, "Saved!")
      Flash.error("Something went wrong.")

      # Good — wrapped, or routed through a helper that wraps
      put_flash(conn, :error, dgettext("auth", "Please try again."))
      put_flash(conn, :error, format_error(reason))

      # Bad — prose attr default (cannot hold dgettext)
      attr :confirm_text, :string, default: "Are you sure?"

      # Good
      attr :confirm_text, :string, default: nil
      # …then in render: {@confirm_text || dgettext("common", "Are you sure?")}

  ## Excluded files

  - Files under `/test/` and `/deps/`
  - The `Flash` helper module itself and `gettext.ex`
  - Any path matching the `:excluded_paths` param — currently the marketing
    surfaces whose localisation is deliberately deferred (the SaaS overlay and
    Core's marketing header/footer). Remove an entry when its area is localised.
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      flash_levels: ~w(error info warning success)a,
      flash_helpers: ~w(error info warning success)a,
      excluded_paths: [
        # Marketing/billing overlay — localised in a later phase.
        "apps/tymeslot_saas/",
        # Core marketing header/footer — localised with the rest of marketing.
        "components/site_components.ex"
      ]
    ],
    explanations: [
      check: """
      A user-facing string literal was not wrapped in gettext. Wrap flash
      messages with `dgettext/3` (or route them through a helper that does),
      and replace a prose `attr` default with `default: nil` plus a render-time
      `dgettext` fallback.
      """,
      params: [
        flash_levels: "Flash levels whose message argument must be translated.",
        flash_helpers: "Function names on the `Flash` helper that take a message.",
        excluded_paths: "Path substrings to skip (deferred-localisation areas)."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    excluded_paths = Params.get(params, :excluded_paths, __MODULE__)

    if excluded?(source_file.filename, excluded_paths) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      levels = MapSet.new(Params.get(params, :flash_levels, __MODULE__))
      helpers = MapSet.new(Params.get(params, :flash_helpers, __MODULE__))
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, levels, helpers))
    end
  end

  # put_flash(conn_or_socket, :level, "literal")
  defp traverse(
         {:put_flash, meta, [_subject, level, message]} = ast,
         issues,
         im,
         levels,
         _helpers
       )
       when is_atom(level) and is_binary(message) do
    maybe_flash_issue(ast, issues, im, meta, level, message, levels)
  end

  # socket |> put_flash(:level, "literal")  — the piped subject is not an arg here
  defp traverse({:put_flash, meta, [level, message]} = ast, issues, im, levels, _helpers)
       when is_atom(level) and is_binary(message) do
    maybe_flash_issue(ast, issues, im, meta, level, message, levels)
  end

  # Flash.error("literal") / Flash.info(...) / Flash.warning(...) / Flash.success(...)
  defp traverse(
         {{:., _, [{:__aliases__, _, mods}, fun]}, meta, [message | _rest]} = ast,
         issues,
         im,
         _levels,
         helpers
       )
       when is_atom(fun) and is_binary(message) do
    if List.last(mods) == :Flash and MapSet.member?(helpers, fun) do
      {ast, [flash_issue(im, meta, fun, message) | issues]}
    else
      {ast, issues}
    end
  end

  # attr :name, :type, default: "prose"
  defp traverse({:attr, meta, [name, _type, opts]} = ast, issues, im, _levels, _helpers)
       when is_atom(name) and is_list(opts) do
    with {:ok, default} <- fetch_default(opts),
         true <- prose_default?(default) do
      {ast, [attr_issue(im, meta, name, default) | issues]}
    else
      _other -> {ast, issues}
    end
  end

  defp traverse(ast, issues, _im, _levels, _helpers), do: {ast, issues}

  defp maybe_flash_issue(ast, issues, im, meta, level, message, levels) do
    if MapSet.member?(levels, level) and user_facing?(message) do
      {ast, [flash_issue(im, meta, level, message) | issues]}
    else
      {ast, issues}
    end
  end

  defp fetch_default(opts) do
    case Keyword.fetch(opts, :default) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  # A literal is "user-facing prose" when it has whitespace between two
  # non-space characters (multi-word), or ends in sentence punctuation or an
  # ellipsis. Single tokens ("column", "Default", "hero-x") are treated as
  # technical and left alone to keep the check gate-safe.
  defp user_facing?(string) do
    trimmed = String.trim(string)

    trimmed != "" and
      (Regex.match?(~r/\S\s\S/u, trimmed) or Regex.match?(~r/(\.\.\.|[.!?…])$/u, trimmed))
  end

  # An `attr` default is prose worth translating only if it is user-facing AND
  # not a CSS/utility-class list. `attr :class` defaults such as "btn
  # btn-primary" or "w-5 h-5" are multi-word but technical — putting them in
  # gettext would let a translation break the layout.
  defp prose_default?(default), do: user_facing?(default) and not css_like?(default)

  # Every whitespace-separated token is a lowercase CSS-utility token (letters,
  # digits, and the CSS punctuation `-_:/[]#.%!`) with no capital letters. Real
  # prose has at least one capitalised word or sentence punctuation and so is
  # not css-like.
  defp css_like?(string) do
    tokens = string |> String.trim() |> String.split(~r/\s+/u, trim: true)

    tokens != [] and
      Enum.all?(tokens, &Regex.match?(~r{^[a-z0-9][a-z0-9:/\[\]#.%!_-]*$}u, &1))
  end

  defp flash_issue(issue_meta, meta, level, message) do
    format_issue(issue_meta,
      message:
        "Untranslated flash message #{inspect(message)} (level `#{level}`). " <>
          "Wrap it in `dgettext/3` or route it through a helper that does.",
      line_no: meta[:line],
      trigger: message
    )
  end

  defp attr_issue(issue_meta, meta, name, default) do
    format_issue(issue_meta,
      message:
        "Prose `attr` default #{inspect(default)} on `#{name}` is not translatable. " <>
          "Use `default: nil` and a render-time `dgettext` fallback.",
      line_no: meta[:line],
      trigger: default
    )
  end

  defp excluded?(filename, excluded_paths) do
    base = Path.basename(filename)

    base in ["gettext.ex", "flash.ex"] or
      String.contains?(filename, "/test/") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/deps/") or
      Enum.any?(excluded_paths, &String.contains?(filename, &1))
  end
end
