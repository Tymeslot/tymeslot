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
      :auth,
      :automation,
      :availability,
      :bookings,
      :calendar,
      :database,
      :demo,
      :emails,
      :infrastructure,
      :integrations,
      :mailer,
      :meetings,
      :meeting_types,
      :notifications,
      :payments,
      :profiles,
      :scheduling,
      :security,
      :themes,
      :utils,
      :video,
      :workers,
      :seo,
      :slack,
      :telegram
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
      :migrations,
      :dev_support
    ],
    special: [
      # Excluded by default in ExUnit.configure — keep in sync with test_helper.exs
      :oauth_integration,
      :calendar_integration,
      :backup_tests,
      # General-purpose exclusion / environment markers
      :external,
      :integration_test,
      :umbrella,
      # Browser-based E2E tests — run with E2E=true mix test --only e2e
      :e2e,
      # Destructive migration tests — run with mix test --include migrations
      :migrations
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
