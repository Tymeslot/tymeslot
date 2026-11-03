defmodule Tymeslot.Onboarding.MeetingSetup do
  @moduledoc """
  The meeting a first-run host sets up in the onboarding wizard: what people
  book them for, for how long, and where.

  The wizard edits one meeting type, the host's first active one by
  position (the one seeded with the profile, `Tymeslot.MeetingTypes.Defaults`),
  and offers three places:

    * `:video`: bound to the host's first active video integration when
      they have one. Without one it is a free-text location labelled
      "Video call": Google Meet, Teams and the rest each need their own
      grant, which the wizard does not ask for, so the host sends the link
      after booking. A `:video` location naming no integration is refused by
      the schema, and would leave the host an error they could not fix here.
    * `:phone`: the booker gives their number.
    * `:in_person`: the address is arranged after booking. An in-person
      location keeps its address in the host's venues, never in the option
      (`LocationOption`), so the wizard asks for none.

  Saves go through `MeetingTypes.update_meeting_type_checked/2`, so the
  ownership checks a form save makes apply here too.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingTypes

  @name_max_length 60
  @duration_range 5..480
  @duration_step 5

  @type choice :: :video | :phone | :in_person
  @type field_error :: :required | :too_long | :invalid
  @type attrs :: %{name: String.t(), duration_minutes: pos_integer(), location: choice() | nil}

  @doc "The longest meeting name the wizard accepts."
  @spec name_max_length() :: pos_integer()
  def name_max_length, do: @name_max_length

  @doc "The shortest and longest duration the wizard accepts, in minutes."
  @spec duration_range() :: Range.t()
  def duration_range, do: @duration_range

  @doc "The step the wizard's duration moves in, in minutes."
  @spec duration_step() :: pos_integer()
  def duration_step, do: @duration_step

  @doc """
  The meeting type the wizard edits, without writing anything: the first
  active one by position, or `nil`.
  """
  @spec current_meeting_type(integer()) :: Ecto.Schema.t() | nil
  def current_meeting_type(user_id),
    do: user_id |> MeetingTypes.get_active_meeting_types() |> List.first()

  @doc """
  The meeting type the wizard edits, made sure of: a host with no type at
  all gets the default seeded, and one whose types are all archived gets a
  fresh default rather than an archived type brought back.
  """
  @spec meeting_type(integer()) :: {:ok, Ecto.Schema.t()} | {:error, term()}
  def meeting_type(user_id) do
    with nil <- current_meeting_type(user_id),
         :ok <- MeetingTypes.seed_default_meeting_types(user_id),
         nil <- current_meeting_type(user_id) do
      MeetingTypes.create_default_meeting_type(user_id)
    else
      %{} = meeting_type -> {:ok, meeting_type}
    end
  end

  @doc """
  Checks the name and duration: a name of 1 to #{@name_max_length}
  characters once trimmed, and a duration in #{inspect(@duration_range)}
  minutes in steps of #{@duration_step}. Returns the cleaned values, or each
  field's error.
  """
  @spec validate(%{
          required(:name) => term(),
          required(:duration_minutes) => term(),
          optional(atom()) => term()
        }) ::
          {:ok, %{name: String.t(), duration_minutes: pos_integer()}}
          | {:error, %{optional(:name | :duration_minutes) => field_error()}}
  def validate(%{name: name, duration_minutes: duration}) do
    name = clean_name(name)

    errors =
      %{}
      |> put_error(:name, name_error(name))
      |> put_error(:duration_minutes, duration_error(duration))

    if errors == %{},
      do: {:ok, %{name: name, duration_minutes: duration}},
      else: {:error, errors}
  end

  @doc """
  The name as it is stored: trimmed, without the null bytes PostgreSQL
  refuses.
  """
  @spec clean_name(term()) :: String.t()
  def clean_name(name) when is_binary(name),
    do: name |> String.replace("\x00", "") |> String.trim()

  def clean_name(_name), do: ""

  defp name_error(""), do: :required

  defp name_error(name),
    do: if(String.length(name) > @name_max_length, do: :too_long)

  defp duration_error(minutes)
       when is_integer(minutes) and minutes in @duration_range and
              rem(minutes, @duration_step) == 0,
       do: nil

  defp duration_error(_minutes), do: :invalid

  defp put_error(errors, _field, nil), do: errors
  defp put_error(errors, field, error), do: Map.put(errors, field, error)

  @doc """
  Saves the name, the duration and, when given, the place. Refused with
  the field errors of `validate/1`, or the save's own reason.
  """
  @spec save(Ecto.Schema.t(), attrs()) :: {:ok, Ecto.Schema.t()} | {:error, term()}
  def save(meeting_type, %{location: choice} = attrs) do
    with {:ok, valid} <- validate(attrs) do
      changes =
        if choice,
          do: Map.put(valid, :locations, [location(choice, meeting_type.user_id)]),
          else: valid

      MeetingTypes.update_meeting_type_checked(meeting_type, changes)
    end
  end

  @doc """
  The host's video integration a `:video` place is bound to: the first
  active one, or `nil`.
  """
  @spec video_integration(integer()) :: struct() | nil
  def video_integration(user_id), do: user_id |> Video.list_active_integrations() |> List.first()

  # The labels `:video`, `:phone` and `:in_person` locations carry are the
  # English defaults the booking page shows in the reader's language
  # (`LocationSelection`). A free-text location is shown as stored, so it
  # is stored in the host's language.
  defp location(:video, user_id) do
    case video_integration(user_id) do
      %{id: id} ->
        %{kind: :video, label: "Video call", video_integration_ids: [id], position: 0}

      nil ->
        %{kind: :custom, label: video_call_label(), details: nil, position: 0}
    end
  end

  defp location(:phone, _user_id),
    do: %{kind: :phone, label: "Phone call", collect_from_guest: true, position: 0}

  defp location(:in_person, _user_id), do: %{kind: :in_person, label: "In person", position: 0}

  defp video_call_label, do: dgettext("booking", "Video call")

  @doc """
  Which of the wizard's places a meeting type is held at, read from its
  first location, or `nil` for one the wizard does not offer.
  """
  @spec choice(Ecto.Schema.t() | nil) :: choice() | nil
  def choice(%{locations: [first | _rest]}), do: location_choice(first)
  def choice(_meeting_type), do: nil

  defp location_choice(%{kind: :video}), do: :video
  defp location_choice(%{kind: :phone}), do: :phone
  defp location_choice(%{kind: :in_person}), do: :in_person

  defp location_choice(%{kind: :custom, label: label, details: details})
       when details in [nil, ""] do
    if label in ["Video call", video_call_label()], do: :video
  end

  defp location_choice(_location), do: nil
end
