defmodule Tymeslot.Test.TagTaxonomy do
  @moduledoc """
  Canonical taxonomy of allowed `@moduletag` values for test modules.

  This is the **single source of truth** for test tags across the entire project.
  `CredoChecks.TestModuleTagRequired` fetches the allowed list from here at runtime,
  so adding or renaming a tag only requires a change in this file.

  ## Tag Categories

  | Category          | Purpose                                                        |
  |-------------------|----------------------------------------------------------------|
  | Domain / area     | Which business domain or feature the tests cover               |
  | Web layer         | Which web-layer concern the tests exercise                     |
  | Test type / layer | What kind of tests these are (unit, integration, schema, etc.) |
  | Special / env     | Tags used for selective exclusion or CI environment control    |

  ## Every Test Module Needs a Domain Tag

  `CredoChecks.TestModuleTagRequired` requires at least one tag from the
  **domain** category, not merely one from the taxonomy. The other categories
  are orthogonal to subject matter: `:unit`, `:live` and `:components` say how a
  test is written or which layer it exercises, and they are spread across every
  feature, so they cannot answer "which tests cover payments?". Targeted runs
  (`mix test --only payments`, `mix test.affected`) select on the domain
  category alone, so a module with no domain tag is unreachable by any of them.

  ## Adding a New Tag

  1. Append the atom to the relevant section in `@taxonomy` below.
  2. Add a brief description in the table above.
  3. Commit the change — the Credo check will accept it automatically on the next run.

  ## Keeping in Sync with `test_helper.exs`

  Tags listed under `:special` that are excluded by default in `ExUnit.configure`
  (e.g. `:oauth_integration`, `:calendar_integration`, `:backup_tests`) must remain
  present here so they are still validated by the Credo check.
  """

  @taxonomy %{
    domain: [
      # Core scheduling & user features
      :analytics,
      :auth,
      :automation,
      :availability,
      :bookings,
      :calendar,
      :dashboard,
      :database,
      :demo,
      :docs,
      :emails,
      :i18n,
      :infrastructure,
      :integrations,
      :legal,
      :mailer,
      :marketing,
      :meetings,
      :meeting_types,
      :notifications,
      :onboarding,
      :payments,
      :polls,
      :profiles,
      :scheduling,
      :security,
      :themes,
      :ui,
      :utils,
      :video,
      :workers,
      :seo,
      :slack,
      :telegram,
      :custom_fields,
      :webhooks,
      # The project's own tooling: mix tasks, the precommit runner, the custom
      # Credo checks. A domain rather than a test type, because it names what
      # the tests are about, not how they are written.
      :dev_support
    ],
    web_layer: [
      :components,
      :controllers,
      :live,
      :plugs,
      :hooks
    ],
    test_type: [
      :unit,
      :integration,
      :schema,
      :queries,
      :migrations
    ],
    special: [
      # Excluded by default in ExUnit.configure — keep in sync with test_helper.exs
      :oauth_integration,
      :calendar_integration,
      :backup_tests,
      # General-purpose exclusion / environment markers
      :external,
      :integration_test,
      # Guards that span both repositories, and so can only run from the SaaS
      # checkout (see tymeslot-saas/test/cross_repo/)
      :cross_repo,
      # Browser-based E2E tests — run with E2E=true mix test --only e2e
      :e2e,
      # Destructive migration tests — run with mix test --include migrations
      :migrations,
      # Needs the git-cliff binary — excluded only where it isn't installed
      # (see Tymeslot.Test.SuiteConfig)
      :git_cliff,
      # Needs a real outbound HTTP proxy plus internet access — run with
      # HTTPS_PROXY=... mix test --only proxy_integration
      :proxy_integration,
      # Compares .pot catalogues against source by running gettext extraction in
      # a subprocess, which force-recompiles the app it extracts from. That is
      # ~100s, and was the largest single cost in the suite that owns these
      # tests, so they are excluded by default and run on a schedule instead —
      # run with mix test --only catalogue_freshness
      :catalogue_freshness,
      # Fetches IANA's TLD list over the network to check priv/tlds.json has
      # not gone stale — run with mix test --only tld_freshness
      :tld_freshness
    ]
  }

  @doc """
  Returns a flat list of every allowed tag atom across all categories.

  Called by `CredoChecks.TestModuleTagRequired` at runtime.
  """
  @spec all() :: [atom()]
  def all do
    @taxonomy
    |> Map.values()
    |> List.flatten()
  end

  @doc """
  Returns the taxonomy map grouped by category, for documentation and tooling.
  """
  @spec by_category() :: %{atom() => [atom()]}
  def by_category, do: @taxonomy
end
