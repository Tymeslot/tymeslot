defmodule Tymeslot.Integrations.Calendar.ProviderConstraintAgreementTest do
  @moduledoc """
  Pins the two halves of the provider whitelist to each other.

  `ProviderConfig.provider_constraint_list/0` feeds `validate_inclusion` on
  `CalendarIntegrationSchema` and `ProviderCalendarEventSchema`; the database's
  `calendar_integrations_provider_check` is installed by a migration that
  derives from nothing. Only a comment has ever asked the two to agree, so
  every drift between them has been silent, and both directions of drift are
  real bugs: a provider the changeset accepts and Postgres refuses fails at
  insert time with a constraint error no user can act on, and a provider
  Postgres accepts while the changeset refuses is a registration that looks
  complete and is not.

  This file reads the constraint that is actually installed rather than a
  copy of the migration's SQL, so it stays honest as providers are added.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Repo

  @constraint "calendar_integrations_provider_check"

  test "the installed CHECK constraint admits exactly the providers ProviderConfig lists" do
    admitted = constraint_providers()

    assert admitted != [], "no #{@constraint} constraint found on calendar_integrations"
    assert Enum.sort(admitted) == Enum.sort(ProviderConfig.provider_constraint_list())
  end

  test "Postgres accepts every provider the constraint list names" do
    providers = ProviderConfig.provider_constraint_list()
    assert providers != []

    integration = insert(:calendar_integration)

    refused =
      Enum.reject(providers, fn provider ->
        match?({:ok, _result}, set_provider(integration.id, provider))
      end)

    assert refused == []
  end

  test "Postgres refuses a provider the constraint list does not name" do
    integration = insert(:calendar_integration)

    refute "lotus_notes" in ProviderConfig.provider_constraint_list()
    assert {:error, %Postgrex.Error{}} = set_provider(integration.id, "lotus_notes")
  end

  # `pg_get_constraintdef/1` renders the `IN (...)` list as an `ANY (ARRAY[...])`
  # of `character varying` literals; only the provider names are quoted.
  defp constraint_providers do
    %{rows: rows} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
        [@constraint]
      )

    case rows do
      [[definition]] ->
        ~r/'([a-z_]+)'/
        |> Regex.scan(definition)
        |> Enum.map(fn [_match, provider] -> provider end)

      _other ->
        []
    end
  end

  defp set_provider(id, provider) do
    Repo.query("UPDATE calendar_integrations SET provider = $1 WHERE id = $2", [provider, id])
  end
end
