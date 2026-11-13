defmodule Tymeslot.MeetingTypes.Defaults do
  @moduledoc """
  The meeting type every new host starts with, seeded once as the
  profile is created. Reached through
  `Tymeslot.MeetingTypes.seed_default_meeting_types/2`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.UUID
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Repo

  # The name and description are translated when seeded (see `templates/0`),
  # so they are stored in the sign-up's language.
  defp templates do
    [
      %{
        name: dgettext("meeting_types", "Intro call"),
        description: dgettext("meeting_types", "A short first conversation"),
        duration_minutes: 30,
        icon: "hero-chat-bubble-left-right"
      }
    ]
  end

  @doc """
  Seeds the default meeting type for a new user, once, as the profile is
  created (`Tymeslot.Profiles.create_profile/1` and the OAuth sign-up, which
  passes its transaction's `repo`). A host who later deletes it keeps none:
  nothing seeds it again.

  A new account has no calendar and no username yet, so the default carries
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

  @doc """
  The attributes of the default meeting type created through the changeset
  (`Tymeslot.MeetingTypes.create_default_meeting_type/1`), for a host who
  has types but none active. The name is the default's, numbered past any
  of `taken_names`.
  """
  @spec default_attrs(integer(), MapSet.t(String.t())) :: map()
  def default_attrs(user_id, taken_names) when is_integer(user_id) do
    [template | _rest] = templates()

    Map.merge(template, %{
      user_id: user_id,
      name: free_name(template.name, taken_names),
      is_active: true,
      locations: [%{kind: :in_person, label: "In person", position: 0}],
      reminder_config: [%{value: 30, unit: "minutes"}]
    })
  end

  defp free_name(name, taken) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> name
      n -> "#{name} #{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # A new account has no calendar yet, so the defaults carry no booking
  # calendar.
  defp default_meeting_type_templates(user_id, now) do
    templates()
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
