defmodule Tymeslot.Integrations.Calendar.PrimarySelection do
  @moduledoc """
  Business logic for automatically selecting a primary calendar integration
  when a new integration is created.

  Ensures that the first integration a user creates is automatically set as
  their primary calendar, using advisory locks to prevent race conditions.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  @doc """
  Creates a new calendar integration with automatic primary setting if it's the first.
  Uses a transaction to ensure atomicity.
  """
  @spec create_with_auto_primary(map()) :: {:ok, CalendarIntegrationSchema.t()} | {:error, term()}
  def create_with_auto_primary(attrs) do
    Repo.transaction(fn ->
      case CalendarIntegrationQueries.create(attrs) do
        {:ok, integration} ->
          maybe_set_as_primary(integration)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # A subscription is read-only, so it can never be the calendar bookings are
  # written to. Promoting one would leave a user whose only calendar is a
  # subscription with a primary that fails every booking write.
  defp maybe_set_as_primary(%{provider: provider} = integration) do
    if ProviderConfig.subscription?(provider) do
      integration
    else
      do_maybe_set_as_primary(integration)
    end
  end

  defp do_maybe_set_as_primary(integration) do
    user_id = integration.user_id

    # Acquire an advisory lock scoped to this user to prevent two concurrent
    # first-integration inserts from both seeing count == 1.
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [1, user_id])

    existing_count = CalendarIntegrationQueries.count_for_user(user_id)

    need_primary =
      case ProfileQueries.get_by_user_id(user_id) do
        {:ok, %{primary_calendar_integration_id: nil}} -> true
        {:ok, _existing_profile} -> existing_count == 1
        {:error, _error_reason} -> existing_count == 1
      end

    if need_primary do
      set_integration_as_primary(integration)
    else
      integration
    end
  end

  defp set_integration_as_primary(integration) do
    case ProfileQueries.set_primary_calendar_integration(
           integration.user_id,
           integration.id
         ) do
      {:ok, _updated_profile} -> integration
      {:error, error_reason} -> Repo.rollback(error_reason)
    end
  end
end
