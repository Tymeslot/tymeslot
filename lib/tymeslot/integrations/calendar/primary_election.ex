defmodule Tymeslot.Integrations.Calendar.PrimaryElection do
  @moduledoc """
  Picks a user's primary (booking) calendar without being asked, when the
  primary goes or a usable calendar arrives; `Calendar.Primary` sets it when
  the user chooses. It decides by two rules and under one lock.

  When the primary stops being usable (it was deleted, switched off by its
  owner, or paused for being unhealthy), `elect_next/2` promotes the newest
  integration that is active, not waiting to be reconnected, and bookable (not
  read-only), or clears the primary when none qualifies.

  When an integration becomes usable (it was created, switched on, or
  reconnected), `adopt_if_vacant/1` makes it the primary if it is bookable,
  not waiting to be reconnected, and the user has no active primary. A
  paused or read-only calendar never becomes the primary, since every
  booking written to it would fail.

  Both run inside `under_lock/3`, which takes
  `CalendarIntegrationQueries.lock_user_profile_and_integrations/1` before
  anything else, so a concurrent create, toggle, pause, delete or reconnect
  cannot decide from a list another one is changing, and every path locks in
  the same order.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.IntegrationCacheQueries
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Primary
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  @type outcome :: {:promoted, pos_integer()} | :cleared | :unchanged

  @doc """
  Runs `fun` in a transaction holding the user's primary lock, returning
  `{:ok, result}`, or `{:error, reason}` when `fun` calls `Repo.rollback/1`.

  `:cache_of` names integrations whose cached events `fun` will reach (a
  delete cascades into them): their integration cache locks are taken
  first, before the profile and integration rows, in the order
  `IntegrationCacheQueries` documents.

  Each change made under the lock (a toggle, a pause, a delete, a new or
  reconnected calendar, a booking calendar made to block) can change what
  the user's booking page offers, so their cached availability is dropped
  once the transaction commits. Nested in a caller's transaction, it is left
  to that caller.
  """
  @spec under_lock(pos_integer(), (-> result), cache_of: [pos_integer()]) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def under_lock(user_id, fun, opts \\ []) do
    result =
      Repo.transaction(fn ->
        IntegrationCacheQueries.lock_cache_class(Keyword.get(opts, :cache_of, []))
        CalendarIntegrationQueries.lock_user_profile_and_integrations(user_id)
        fun.()
      end)

    with {:ok, _value} <- result,
         false <- CalendarIntegrationQueries.in_transaction?() do
      Availability.changed(user_id)
    end

    result
  end

  @doc """
  The user's stored primary integration id, or nil. Read under the lock, it
  is the primary every decision in that transaction starts from.
  """
  @spec stored_primary_id(pos_integer()) :: pos_integer() | nil
  def stored_primary_id(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, %{primary_calendar_integration_id: id}} -> id
      _no_profile -> nil
    end
  end

  @doc """
  Makes the next eligible integration of `user_id`, other than those in
  `exclude_ids`, the primary, or clears the primary when none is eligible.
  Call it inside `under_lock/3`.

  A candidate refused by `Calendar.Primary.set_primary_calendar_integration/2`
  (it changed or vanished since it was listed) is excluded and the next one
  tried; each pass excludes one more id, so this terminates.
  """
  @spec elect_next(pos_integer(), [pos_integer()]) :: outcome()
  def elect_next(user_id, exclude_ids) do
    candidates =
      user_id
      |> Management.list_active_calendar_integrations()
      |> Enum.reject(&(&1.id in exclude_ids or &1.needs_reauth))
      |> BookingEligibility.filter_bookable()
      |> Enum.sort(&newer?/2)

    case candidates do
      [next | _rest] ->
        case Primary.set_primary_calendar_integration(user_id, next.id) do
          {:ok, _integration} -> {:promoted, next.id}
          {:error, _reason} -> elect_next(user_id, [next.id | exclude_ids])
        end

      [] ->
        case ProfileQueries.clear_primary_calendar_integration(user_id) do
          {:ok, _profile} -> :cleared
          _error -> :unchanged
        end
    end
  end

  @doc """
  Adopts `integration` as its user's primary calendar when they have none, or
  the one they have is inactive or gone. Call it inside `under_lock/3`.

  A read-only integration is never adopted: it blocks time but refuses every
  write. Nor is one waiting to be reconnected, which `elect_next/2` would
  pass over too: its writes fail until its owner reconnects it, and the
  reconnect clears the flag before adopting. Whether `integration` is still active is checked on the stored row
  by `Calendar.Primary.set_primary_calendar_integration/2`, so a struct read
  before the lock cannot adopt a calendar paused since.

  The decision reads the stored primary row, not a decrypted one: a primary
  whose credentials do not decrypt for now (a rotated key, say) is still the
  user's chosen calendar, and another becoming usable must not demote it.
  """
  @spec adopt_if_vacant(CalendarIntegrationSchema.t()) :: :adopted | :unchanged
  def adopt_if_vacant(%{id: id, user_id: user_id} = integration) do
    with false <- integration.needs_reauth,
         true <- BookingEligibility.bookable?(integration),
         false <- active_primary?(user_id),
         {:ok, _primary} <- Primary.set_primary_calendar_integration(user_id, id) do
      :adopted
    else
      _keep -> :unchanged
    end
  end

  defp active_primary?(user_id) do
    case stored_primary_id(user_id) do
      nil -> false
      id -> active_row?(CalendarIntegrationQueries.get(id), user_id)
    end
  end

  defp active_row?({:ok, %{user_id: user_id, is_active: true}}, user_id), do: true

  defp active_row?(
         {:error, :requires_reencryption, %{user_id: user_id, is_active: true}},
         user_id
       ),
       do: true

  defp active_row?(_inactive_or_gone, _user_id), do: false

  # Newest first; the id breaks a tie between rows inserted in one second.
  defp newer?(a, b) do
    case DateTime.compare(a.inserted_at, b.inserted_at) do
      :gt -> true
      :lt -> false
      :eq -> a.id >= b.id
    end
  end
end
