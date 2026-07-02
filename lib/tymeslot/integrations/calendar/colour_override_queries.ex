defmodule Tymeslot.Integrations.Calendar.ColourOverrideQueries do
  @moduledoc """
  Data access for `event_colour_overrides`. All `Repo` calls for the durable
  per-event colour override live here (RepoCallBoundary).
  """
  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.ColourOverride
  alias Tymeslot.Repo

  @spec set_external(integer(), integer(), String.t(), String.t()) ::
          {:ok, ColourOverride.t()} | {:error, Ecto.Changeset.t()}
  def set_external(user_id, integration_id, uid, colour) do
    attrs = %{
      user_id: user_id,
      calendar_integration_id: integration_id,
      provider_uid: uid,
      colour: colour
    }

    upsert(attrs, &external_match/2, {user_id, integration_id, uid})
  end

  @spec set_meeting(integer(), Ecto.UUID.t(), String.t()) ::
          {:ok, ColourOverride.t()} | {:error, Ecto.Changeset.t()}
  def set_meeting(user_id, meeting_id, colour) do
    attrs = %{user_id: user_id, meeting_id: meeting_id, colour: colour}

    upsert(attrs, &meeting_match/2, {user_id, meeting_id})
  end

  @spec clear_external(integer(), integer(), String.t()) :: :ok
  def clear_external(user_id, integration_id, uid) do
    Repo.delete_all(external_match(ColourOverride, {user_id, integration_id, uid}))
    :ok
  end

  @spec clear_meeting(integer(), Ecto.UUID.t()) :: :ok
  def clear_meeting(user_id, meeting_id) do
    Repo.delete_all(meeting_match(ColourOverride, {user_id, meeting_id}))
    :ok
  end

  @doc """
  All of a user's overrides as a lookup map: `{:meeting, id} => colour` and
  `{:external, integration_id, uid} => colour`.
  """
  @spec for_user(integer()) :: %{optional(tuple()) => String.t()}
  def for_user(user_id) do
    from(o in ColourOverride, where: o.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(&override_entry/1)
  end

  defp override_entry(%ColourOverride{meeting_id: meeting_id} = override)
       when is_binary(meeting_id),
       do: {{:meeting, meeting_id}, override.colour}

  defp override_entry(%ColourOverride{} = override),
    do: {{:external, override.calendar_integration_id, override.provider_uid}, override.colour}

  defp external_match(query, {user_id, integration_id, uid}) do
    from o in query,
      where:
        o.user_id == ^user_id and o.calendar_integration_id == ^integration_id and
          o.provider_uid == ^uid
  end

  defp meeting_match(query, {user_id, meeting_id}) do
    from o in query, where: o.user_id == ^user_id and o.meeting_id == ^meeting_id
  end

  defp upsert(attrs, match_fun, match_args) do
    case Repo.one(match_fun.(ColourOverride, match_args)) do
      nil -> %ColourOverride{} |> ColourOverride.changeset(attrs) |> Repo.insert()
      existing -> existing |> ColourOverride.changeset(attrs) |> Repo.update()
    end
  end
end
