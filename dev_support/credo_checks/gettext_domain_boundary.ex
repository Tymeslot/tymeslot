defmodule CredoChecks.GettextDomainBoundary do
  @moduledoc """
  Flags bare `gettext/1,2` and `ngettext/3,4` calls and `dgettext`/`dngettext`
  calls that target an unknown domain.

  Every translatable string must declare *where in the app it lives* through an
  explicit gettext domain. Bare `gettext("...")` silently targets the implicit
  `default` domain, which turns that catalog into an unstructured catch-all —
  exactly what this project's domain-per-area split is designed to avoid. Always
  reach for `dgettext/3` (or `dngettext/4` for plurals) with one of the known
  domains.

  ## Known domains

  Catalogues are split small and per app area, so that a change to one area means
  reading one small `.po`. The `:domains` param below is the enforced list, and
  the `tymeslot-translations` skill describes what belongs in each domain.
  `CredoChecks.GettextDomainBoundaryTest` fails if this list and the `.pot`
  templates in `priv/gettext` disagree, so adding a domain means extracting it
  and listing it here in the same change.

  This list covers Core only, since the check ships with Core and must carry no
  knowledge of the managed offering. A repository with domains of its own
  passes the full list (these plus its own) through the `:domains` param in its
  `.credo.exs`; Credo replaces params rather than merging them.

  Configure the allowlist with the `:domains` param.

  ## Excluded files

  - Files under `/test/` — test support and assertions
  - `gettext.ex` — the backend definition itself
  - Files under `/deps/`

  ## Examples

      # Bad — implicit default domain
      gettext("Confirm your booking")
      ngettext("1 slot", "%{count} slots", count)

      # Bad — unknown domain (typo / not in the taxonomy)
      dgettext("dashboard", "Users")

      # Good — explicit, known domain
      dgettext("booking", "Confirm your booking")
      dngettext("booking", "1 slot", "%{count} slots", count)
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      domains: ~w(
        booking booking_manage booking_polls embed errors common
        emails emails_account emails_booking emails_booking_requests
        emails_integrations emails_polls
        auth account onboarding onboarding_wizard
        dashboard_common
        dashboard_home dashboard_meeting_types dashboard_meeting_form
        dashboard_availability dashboard_calendar_settings dashboard_calendar
        dashboard_calendar_events dashboard_integrations dashboard_calendar_providers
        dashboard_automation dashboard_automation_chat dashboard_appearance
        dashboard_embed dashboard_payments dashboard_bookings dashboard_profile
        dashboard_analytics dashboard_admin dashboard_video
      )
    ],
    explanations: [
      check: """
      Translatable strings must declare their app area through an explicit
      gettext domain. Replace bare `gettext`/`ngettext` with `dgettext`/`dngettext`
      and a known domain, and fix any domain that is not in the allowlist.
      """,
      params: [
        domains: "List of allowed gettext domains."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @bare_calls [:gettext, :ngettext]
  @domained_calls [:dgettext, :dngettext]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    if excluded?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      domains = MapSet.new(Params.get(params, :domains, __MODULE__))
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, domains))
    end
  end

  # Bare gettext/ngettext — implicit default domain.
  defp traverse({call, meta, args} = ast, issues, issue_meta, _domains)
       when call in @bare_calls and is_list(args) and args != [] do
    issue =
      format_issue(issue_meta,
        message:
          "`#{call}` targets the implicit `default` domain. Use " <>
            "`d#{call}/#{length(args) + 1}` with an explicit domain instead.",
        line_no: meta[:line],
        trigger: Atom.to_string(call)
      )

    {ast, [issue | issues]}
  end

  # dgettext/dngettext with a string-literal domain — validate against allowlist.
  defp traverse({call, meta, [domain | _rest]} = ast, issues, issue_meta, domains)
       when call in @domained_calls and is_binary(domain) do
    if MapSet.member?(domains, domain) do
      {ast, issues}
    else
      issue =
        format_issue(issue_meta,
          message:
            "Unknown gettext domain #{inspect(domain)}. Allowed domains: " <>
              (domains |> Enum.sort() |> Enum.join(", ")) <> ".",
          line_no: meta[:line],
          trigger: domain
        )

      {ast, [issue | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta, _domains), do: {ast, issues}

  defp excluded?(filename) do
    Path.basename(filename) == "gettext.ex" or
      String.contains?(filename, "/test/") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/deps/")
  end
end
