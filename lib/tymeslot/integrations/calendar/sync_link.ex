defmodule Tymeslot.Integrations.Calendar.SyncLink do
  @moduledoc """
  The organiser's cross-calendar mirroring configuration: which calendar's
  events get a placeholder written onto which other calendar, and under what
  privacy tier.

  A focused sibling of `Tymeslot.Integrations.Calendar` in the shape
  `Tymeslot.Integrations.Calendar.Appearance` established: the context owns
  connecting and syncing calendars, and this owns the relationships configured
  between the ones already connected.

  ## Why authorisation lives here and nowhere else

  `CalendarSyncLinkQueries` is not user-scoped. `get/1`, `update/2` and
  `delete/1` take an id and act on whatever row carries it, so a LiveView
  reaching for a query module directly hands the browser a way to edit another
  organiser's links by guessing an integer. Every write on this module
  therefore takes the acting user's id and verifies ownership before touching a
  row, answering `{:error, :not_found}` — not `:forbidden` — so a forged id
  cannot be used to probe which ids exist.

  A sync link is harder to guard than an appearance row, because it names
  *two* integrations. Both are forgeable and both are checked: naming a
  stranger's calendar as either end fails, and the check runs before the
  changeset so no row is written and no error message reveals anything about
  the calendar named. `owned_by?/2` rather than `get_for_user/2`, following
  `Appearance.with_owned_integration/3`: the latter decrypts credentials and
  can answer `:requires_reencryption`, neither of which has any bearing on
  whether a link may be configured.

  ## Why the context loads the target integration

  Two changeset rules — a read-only subscription can never be a mirror target,
  and the CalDAV family ignores a calendar id on write — depend on the target's
  provider, which a changeset cannot look up. `CalendarSyncLinkSchema` takes it
  as the virtual `:target_provider` field and, crucially, *skips both rules*
  when it is absent rather than failing. A caller that forgets it gets a link
  pointing at an ICS feed that will fail on every mirror write forever. This
  module is the one place that guarantees it is supplied: the ownership check
  already loads the target integration, so the provider is in hand and there is
  no second query to pay for.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema

  @type result ::
          {:ok, CalendarSyncLinkSchema.t()} | {:error, :not_found | Ecto.Changeset.t()}

  @doc """
  Every link the organiser has configured, with both ends preloaded for the
  dashboard to name them.
  """
  @spec list_links(integer()) :: [CalendarSyncLinkSchema.t()]
  def list_links(user_id) when is_integer(user_id),
    do: CalendarSyncLinkQueries.list_for_user(user_id)

  @doc """
  Configures a new mirroring relationship.

  `attrs` carries the two integration ids and the optional presentation
  choices; `user_id` and `target_provider` are supplied here and any value the
  caller passed for them is overwritten, so a form parameter cannot claim
  another organiser's id or a provider its target does not have.
  """
  @spec create_link(integer(), map()) :: result()
  def create_link(user_id, attrs) when is_integer(user_id) do
    source_id = fetch_id(attrs, :source_integration_id)
    target_id = fetch_id(attrs, :target_integration_id)

    with_owned_pair(user_id, source_id, target_id, fn target_provider ->
      attrs
      |> normalise(user_id, source_id, target_id, target_provider)
      |> CalendarSyncLinkQueries.create()
    end)
  end

  @doc """
  Edits an existing link.

  The target may move, so ownership is re-verified against the target the
  attributes ask for rather than the one already stored, and the provider
  handed to the changeset is that new target's.
  """
  @spec update_link(integer(), integer() | any(), map()) :: result()
  def update_link(user_id, link_id, attrs) when is_integer(user_id) do
    with {:ok, link} <- owned_link(user_id, link_id) do
      source_id = fetch_id(attrs, :source_integration_id) || link.source_integration_id
      target_id = fetch_id(attrs, :target_integration_id) || link.target_integration_id

      with_owned_pair(user_id, source_id, target_id, fn target_provider ->
        CalendarSyncLinkQueries.update(
          link,
          normalise(attrs, user_id, source_id, target_id, target_provider)
        )
      end)
    end
  end

  @doc """
  Pauses or resumes one link.

  Pausing leaves the placeholders already written on the target in place; only
  deleting the link tears the mapping rows down. Routed through `update_link/3`
  so a paused link is re-validated against its target's provider — an
  integration reconnected as a subscription while a link pointed at it should
  not be resumable.
  """
  @spec toggle_enabled(integer(), integer() | any(), boolean()) :: result()
  def toggle_enabled(user_id, link_id, enabled) when is_boolean(enabled),
    do: update_link(user_id, link_id, %{"enabled" => enabled})

  @doc """
  Removes a link, and with it the mapping rows recording where its mirrors were
  written. See `CalendarSyncLinkQueries.delete/1`: the placeholders themselves
  are not withdrawn by this.
  """
  @spec delete_link(integer(), integer() | any()) :: result()
  def delete_link(user_id, link_id) when is_integer(user_id) do
    with {:ok, link} <- owned_link(user_id, link_id) do
      CalendarSyncLinkQueries.delete(link)
    end
  end

  @doc """
  A changeset for the dashboard form, carrying the target's provider so the
  form re-renders under the same rules the write will apply.
  """
  @spec change_link(CalendarSyncLinkSchema.t(), map()) :: Ecto.Changeset.t()
  def change_link(%CalendarSyncLinkSchema{} = link, attrs \\ %{}),
    do: CalendarSyncLinkQueries.change(link, attrs)

  # Both ends must belong to the acting user. The target's check is
  # `provider_for_owner/2` rather than `owned_by?/2` because the same query
  # answers ownership and yields the provider the changeset needs; the source
  # is only ever an ownership question, so it uses the cheaper predicate.
  defp with_owned_pair(user_id, source_id, target_id, fun) do
    with true <- CalendarIntegrationQueries.owned_by?(source_id, user_id),
         {:ok, target_provider} <-
           CalendarIntegrationQueries.provider_for_owner(target_id, user_id) do
      fun.(target_provider)
    else
      _not_owned -> {:error, :not_found}
    end
  end

  defp owned_link(user_id, link_id) do
    case CalendarSyncLinkQueries.get(link_id) do
      {:ok, %{user_id: ^user_id} = link} -> {:ok, link}
      {:ok, _someone_elses} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # The three fields the caller may not choose: the owner, and the ids the
  # ownership check just validated. Written with string keys because the form
  # params they merge into are string-keyed, and Ecto's cast rejects a map
  # mixing both.
  defp normalise(attrs, user_id, source_id, target_id, target_provider) do
    attrs
    |> stringify_keys()
    |> Map.merge(%{
      "user_id" => user_id,
      "source_integration_id" => source_id,
      "target_integration_id" => target_id,
      "target_provider" => target_provider
    })
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # Ids arrive from form params as strings and from code as integers. Anything
  # that is not one of those — including a string with trailing rubbish — is
  # treated as absent, so it reaches the ownership check as `nil` and fails
  # there rather than raising in `String.to_integer/1`.
  defp fetch_id(attrs, key) do
    attrs
    |> Map.get(key, Map.get(attrs, Atom.to_string(key)))
    |> cast_id()
  end

  defp cast_id(id) when is_integer(id), do: id

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _not_an_id -> nil
    end
  end

  defp cast_id(_other), do: nil
end
