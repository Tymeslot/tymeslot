defmodule Tymeslot.MeetingTypes.Defaults do
  @moduledoc """
  The two meeting types every new host starts with, seeded once as the
  profile is created. Reached through
  `Tymeslot.MeetingTypes.seed_default_meeting_types/2`.
  """

  alias Ecto.UUID
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Repo

  # What tells the defaults apart, in the order they are listed.
  @templates [
    %{
      name: "15 Minutes",
      description: "Quick chat or brief consultation",
      duration_minutes: 15,
      icon: "hero-bolt"
    },
    %{
      name: "30 Minutes",
      description: "In-depth discussion or detailed review",
      duration_minutes: 30,
      icon: "hero-rocket-launch"
    }
  ]

  @doc """
  Seeds the two default meeting types for a new user, once, as the profile is
  created (`Tymeslot.Profiles.create_profile/1` and the OAuth sign-up, which
  passes its transaction's `repo`). A host who later deletes them keeps none:
  nothing seeds them again.

  A new account has no calendar and no username yet, so the defaults carry
  no booking calendar and there is no booking page to publish. A seed that
  meets types already there (a retried sign-up) inserts nothing.
  """
  @spec seed_default_meeting_types(integer(), Ecto.Repo.t()) :: :ok
  def seed_default_meeting_types(user_id, repo \\ Repo) when is_integer(user_id) do
    now = DateTime.utc_now(:second)

    user_id
    |> default_meeting_type_templates(now)
    |> MeetingTypeQueries.insert_defaults(repo)

    :ok
  end

  # A new account has no calendar yet, so the defaults carry no booking
  # calendar.
  defp default_meeting_type_templates(user_id, now) do
    @templates
    |> Enum.with_index()
    |> Enum.map(fn {template, sort_order} ->
      Map.merge(template, %{
        user_id: user_id,
        sort_order: sort_order,
        is_active: true,
        allow_video: false,
        locations: [default_in_person_location()],
        calendar_integration_id: nil,
        target_calendar_id: nil,
        reminder_config: [%{value: 30, unit: "minutes"}],
        inserted_at: now,
        updated_at: now
      })
    end)
  end

  # These templates are bulk-inserted, so they bypass the changeset. Ecto
  # still dumps the embed on the way to the database and refuses anything but
  # the struct, so the struct is what the template carries.
  # The label is stored as the English default on purpose:
  # `LocationSelection.options/1` shows it in the reader's language.
  defp default_in_person_location do
    %LocationOption{
      id: UUID.generate(),
      kind: :in_person,
      label: "In person",
      position: 0
    }
  end
end
