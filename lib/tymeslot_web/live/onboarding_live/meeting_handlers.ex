defmodule TymeslotWeb.OnboardingLive.MeetingHandlers do
  @moduledoc """
  The meeting step's state and events: the meeting people book
  (`Tymeslot.Onboarding.MeetingSetup`) and the week they can book it in
  (`Tymeslot.Availability.set_weekly_hours/2`).

  The step edits two forms held on the socket:

    * `meeting_form`: the name as typed, the duration (a preset or the
      "Other" number), and the place. The stage draws it as it changes
      (`meeting_preview/1`); it is saved when the host leaves a field, picks
      a chip or a place, and before Continue moves on, never on every key.
    * `hours_form`: the days and the one window, and the preset chip that
      shows. A change is saved straight away (the time selects reach here
      debounced by the browser).

  A save that changes what the week offers (the duration, the place, the
  hours) reads the stage's week again (`WeekReveal.refresh/1`), so the
  times reshape. Errors sit in `meeting_errors`, one message per field, and
  any error keeps Continue disabled (`invalid?/1`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Phoenix.Component
  alias Tymeslot.Availability
  alias Tymeslot.Onboarding.MeetingSetup
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.OnboardingLive.WeekReveal

  @duration_presets [15, 30, 45, 60]

  @hour_presets [
    weekdays: %{days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00"},
    mornings: %{days: [1, 2, 3, 4, 5], start: "08:00", end: "12:00"},
    afternoons: %{days: [1, 2, 3, 4, 5], start: "13:00", end: "18:00"}
  ]

  @default_hours Keyword.fetch!(@hour_presets, :weekdays)

  @type socket :: Phoenix.LiveView.Socket.t()

  # -------------------------------------------------------------------
  # State
  # -------------------------------------------------------------------

  @doc """
  The step's state before anything is read: no meeting type, the default
  week. The disconnected render of any other step stays at this.
  """
  @spec assign_blank(socket()) :: socket()
  def assign_blank(socket) do
    Component.assign(socket,
      meeting_type: nil,
      meeting_form: form_from(nil),
      meeting_errors: %{},
      hours_form: Map.put(@default_hours, :preset, :weekdays),
      video_integration: nil,
      meeting_loaded: false
    )
  end

  @doc """
  Reads the step's state from the host's meeting type, week and video
  integrations. The connected mount does it for every step (the stage
  names the meeting on all of them) and makes sure there is a meeting type
  to edit; the disconnected render does it only for the meeting step, and
  only reads.
  """
  @spec load(socket(), boolean()) :: socket()
  def load(%{assigns: %{profile: nil}} = socket, _connected?), do: socket

  def load(%{assigns: %{current_user: user, profile: profile}} = socket, connected?) do
    meeting_type = load_meeting_type(user.id, profile, connected?)
    hours = Availability.weekly_hours(profile.id) || @default_hours

    Component.assign(socket,
      meeting_type: meeting_type,
      meeting_form: form_from(meeting_type),
      meeting_errors: %{},
      hours_form: Map.put(hours, :preset, preset_for(hours)),
      video_integration: MeetingSetup.video_integration(user.id),
      meeting_loaded: true
    )
  end

  @doc "Loads the step's state on entering it, unless it already is."
  @spec ensure_loaded(socket(), boolean()) :: socket()
  def ensure_loaded(%{assigns: %{meeting_loaded: true}} = socket, _connected?), do: socket
  def ensure_loaded(socket, connected?), do: load(socket, connected?)

  defp load_meeting_type(user_id, _profile, true) do
    case MeetingSetup.meeting_type(user_id) do
      {:ok, meeting_type} -> meeting_type
      {:error, _reason} -> nil
    end
  end

  defp load_meeting_type(user_id, _profile, false), do: MeetingSetup.current_meeting_type(user_id)

  defp form_from(nil),
    do: %{name: "", duration: 30, other: false, duration_input: "30", location: nil}

  defp form_from(meeting_type) do
    duration = meeting_type.duration_minutes

    %{
      name: meeting_type.name || "",
      duration: duration,
      other: duration not in @duration_presets,
      duration_input: to_string(duration),
      location: MeetingSetup.choice(meeting_type)
    }
  end

  @doc "The duration chips, in minutes; \"Other\" follows them."
  @spec duration_presets() :: [pos_integer()]
  def duration_presets, do: @duration_presets

  @doc "The hours presets' keys, in the order the chips show them."
  @spec hour_presets() :: [atom()]
  def hour_presets, do: Keyword.keys(@hour_presets)

  # A week whose days differ is the host's own, whatever its first day says.
  defp preset_for(%{uniform: false}), do: :custom

  defp preset_for(hours) do
    shape = Map.take(hours, [:days, :start, :end])

    Enum.find_value(@hour_presets, :custom, fn {key, preset} ->
      if preset == %{shape | days: Enum.sort(shape.days)}, do: key
    end)
  end

  @doc """
  The meeting as the stage draws it, from the form as the host edits it:
  a name being typed shows at once, and a blank one or a duration that is
  not valid yet shows what is saved.
  """
  @spec meeting_preview(map()) :: map() | nil
  def meeting_preview(%{meeting_type: nil}), do: nil

  def meeting_preview(%{meeting_type: meeting_type, meeting_form: form}) do
    name =
      case MeetingSetup.clean_name(form.name) do
        "" -> meeting_type.name
        typed -> String.slice(typed, 0, MeetingSetup.name_max_length())
      end

    %{
      name: name,
      duration_minutes: valid_duration(form.duration) || meeting_type.duration_minutes,
      location: form.location
    }
  end

  def meeting_preview(_assigns), do: nil

  defp valid_duration(minutes) do
    case MeetingSetup.validate(%{name: "x", duration_minutes: minutes}) do
      {:ok, _valid} -> minutes
      {:error, _errors} -> nil
    end
  end

  @doc "Whether a field of the step is in error, which keeps Continue disabled."
  @spec invalid?(map()) :: boolean()
  def invalid?(%{meeting_errors: errors}), do: errors != %{}
  def invalid?(_assigns), do: false

  # -------------------------------------------------------------------
  # Meeting events
  # -------------------------------------------------------------------

  @doc """
  The meeting form changed (a key typed in the name or the "Other"
  duration): updates the form and its errors, which the stage follows. No
  save.
  """
  @spec handle_change(map(), socket()) :: {:noreply, socket()}
  def handle_change(%{"meeting" => params}, socket) do
    form = socket.assigns.meeting_form

    form =
      form
      |> maybe_put(:name, params["name"])
      |> put_duration_input(params["duration_input"])

    {:noreply, socket |> Component.assign(:meeting_form, form) |> validate_meeting()}
  end

  def handle_change(_params, socket), do: {:noreply, socket}

  @doc "A field was left, or the form submitted: saves what changed."
  @spec handle_save(socket()) :: {:noreply, socket()}
  def handle_save(socket), do: {:noreply, save_meeting(socket)}

  @doc """
  A suggestion chip, sent as its position in `name_suggestions/0`, fills the
  name and saves it.
  """
  @spec handle_suggestion(String.t(), socket()) :: {:noreply, socket()}
  def handle_suggestion(index, socket) do
    with {position, ""} <- Integer.parse(index),
         name when is_binary(name) <- Enum.at(name_suggestions(), position) do
      {:noreply, socket |> update_form(:name, name) |> save_meeting()}
    else
      _unknown -> {:noreply, socket}
    end
  end

  @doc "The chip that matches the name, by position, or `nil`."
  @spec suggestion_index(String.t()) :: non_neg_integer() | nil
  def suggestion_index(name),
    do: Enum.find_index(name_suggestions(), &(&1 == MeetingSetup.clean_name(name)))

  @doc """
  A duration chip: a preset saves at once; "Other" opens the number field
  with the current length in it, and saves when that is left.
  """
  @spec handle_duration(String.t(), socket()) :: {:noreply, socket()}
  def handle_duration("other", socket) do
    {:noreply, update_form(socket, :other, true)}
  end

  def handle_duration(value, socket) do
    case Integer.parse(value) do
      {minutes, ""} when minutes in @duration_presets ->
        form = %{
          socket.assigns.meeting_form
          | duration: minutes,
            other: false,
            duration_input: value
        }

        {:noreply,
         socket |> Component.assign(:meeting_form, form) |> validate_meeting() |> save_meeting()}

      _other ->
        {:noreply, socket}
    end
  end

  @doc "A place chip, saved at once."
  @spec handle_location(String.t(), socket()) :: {:noreply, socket()}
  def handle_location(value, socket) do
    case Enum.find([:video, :phone, :in_person], &(Atom.to_string(&1) == value)) do
      nil -> {:noreply, socket}
      choice -> {:noreply, socket |> update_form(:location, choice) |> save_meeting()}
    end
  end

  defp maybe_put(form, _key, nil), do: form
  defp maybe_put(form, key, value), do: Map.put(form, key, value)

  defp put_duration_input(form, nil), do: form

  defp put_duration_input(form, input) do
    duration =
      case Integer.parse(String.trim(input)) do
        {minutes, ""} -> minutes
        _blank_or_invalid -> nil
      end

    %{form | duration_input: input, duration: duration}
  end

  defp update_form(socket, key, value) do
    socket
    |> Component.assign(:meeting_form, Map.put(socket.assigns.meeting_form, key, value))
    |> validate_meeting()
  end

  defp validate_meeting(socket) do
    form = socket.assigns.meeting_form

    errors =
      case MeetingSetup.validate(%{name: form.name, duration_minutes: form.duration}) do
        {:ok, _valid} ->
          %{}

        {:error, errors} ->
          Map.new(errors, fn {field, error} -> {field, message(field, error)} end)
      end

    # A save's own refusal and the hours' error stay until their next save,
    # but a place refused goes once the host is back on the stored one.
    kept =
      socket.assigns.meeting_errors
      |> Map.take([:location, :hours])
      |> then(&if(location_stored?(socket.assigns), do: Map.delete(&1, :location), else: &1))

    Component.assign(socket, :meeting_errors, Map.merge(kept, errors))
  end

  defp location_stored?(%{meeting_type: nil}), do: false

  defp location_stored?(%{meeting_type: meeting_type, meeting_form: form}),
    do: form.location == MeetingSetup.choice(meeting_type)

  # Saves the form when it is valid and differs from what is stored. A
  # change of length or place reads the week again.
  defp save_meeting(%{assigns: %{meeting_type: nil}} = socket), do: socket

  defp save_meeting(socket) do
    %{meeting_type: meeting_type, meeting_form: form} = socket.assigns
    # The place is written only when it changed, so a rename keeps the
    # stored location as it is.
    location = if form.location != MeetingSetup.choice(meeting_type), do: form.location
    attrs = %{name: form.name, duration_minutes: form.duration, location: location}

    cond do
      Map.take(socket.assigns.meeting_errors, [:name, :duration_minutes]) != %{} -> socket
      not changed?(meeting_type, attrs) -> socket
      true -> do_save(socket, meeting_type, attrs)
    end
  end

  defp changed?(meeting_type, attrs) do
    MeetingSetup.clean_name(attrs.name) != meeting_type.name or
      attrs.duration_minutes != meeting_type.duration_minutes or attrs.location != nil
  end

  defp do_save(socket, meeting_type, attrs) do
    case MeetingSetup.save(meeting_type, attrs) do
      {:ok, saved} ->
        reshaped? =
          saved.duration_minutes != meeting_type.duration_minutes or attrs.location != nil

        socket
        |> Component.assign(
          meeting_type: saved,
          meeting_errors: Map.delete(socket.assigns.meeting_errors, :location)
        )
        |> then(&if(reshaped?, do: WeekReveal.refresh(&1), else: &1))

      {:error, reason} ->
        Component.assign(
          socket,
          :meeting_errors,
          Map.merge(socket.assigns.meeting_errors, save_errors(reason))
        )
    end
  end

  defp save_errors(%{} = errors) when not is_struct(errors),
    do: Map.new(errors, fn {field, error} -> {field, message(field, error)} end)

  defp save_errors(%Changeset{errors: errors}) do
    case Keyword.get(errors, :name) do
      nil -> %{location: message(:save, :failed)}
      error -> %{name: Forms.translate_error(error)}
    end
  end

  defp save_errors(reason)
       when reason in [:invalid_video_integration, :video_integration_required, :invalid_location],
       do: %{location: message(:location, :video_unavailable)}

  defp save_errors(_reason), do: %{location: message(:save, :failed)}

  # -------------------------------------------------------------------
  # Hours events
  # -------------------------------------------------------------------

  @doc "A preset chip: writes its week. \"Custom\" only shows the controls as they are."
  @spec handle_hours_preset(String.t(), socket()) :: {:noreply, socket()}
  def handle_hours_preset("custom", socket) do
    hours = %{socket.assigns.hours_form | preset: :custom}
    {:noreply, Component.assign(socket, :hours_form, hours)}
  end

  def handle_hours_preset(value, socket) do
    case Enum.find(@hour_presets, fn {key, _hours} -> Atom.to_string(key) == value end) do
      {key, hours} -> {:noreply, put_hours(socket, Map.put(hours, :preset, key))}
      nil -> {:noreply, socket}
    end
  end

  @doc "A day toggle: adds or removes the day, and writes the week."
  @spec handle_toggle_day(String.t(), socket()) :: {:noreply, socket()}
  def handle_toggle_day(value, socket) do
    case Integer.parse(value) do
      {day, ""} when day in 1..7 ->
        hours = socket.assigns.hours_form

        days =
          if day in hours.days,
            do: List.delete(hours.days, day),
            else: Enum.sort([day | hours.days])

        {:noreply, put_hours(socket, reshaped(hours, %{days: days}))}

      _other ->
        {:noreply, socket}
    end
  end

  @doc "The start or end time changed (debounced in the browser): writes the week."
  @spec handle_hours_change(map(), socket()) :: {:noreply, socket()}
  def handle_hours_change(%{"hours" => params}, socket) do
    hours = socket.assigns.hours_form
    changes = %{start: params["start"] || hours.start, end: params["end"] || hours.end}

    if changes.start == hours.start and changes.end == hours.end,
      do: {:noreply, socket},
      else: {:noreply, put_hours(socket, reshaped(hours, changes))}
  end

  def handle_hours_change(_params, socket), do: {:noreply, socket}

  # A change away from a preset shows "Custom"; one that lands on a preset's
  # shape shows that preset.
  defp reshaped(hours, changes) do
    hours = Map.merge(hours, changes)
    %{hours | preset: preset_for(hours)}
  end

  # Writes a valid week and reads the stage's week again; an invalid one is
  # kept on the form, unsaved, with its error.
  defp put_hours(socket, hours) do
    socket = Component.assign(socket, :hours_form, hours)

    result =
      with :ok <- Availability.validate_weekly_hours(hours),
           %{id: profile_id} <- socket.assigns.profile || {:error, :no_profile} do
        Availability.set_weekly_hours(profile_id, Map.take(hours, [:days, :start, :end]))
      end

    case result do
      :ok ->
        socket
        |> put_error(:hours, nil)
        |> WeekReveal.refresh()

      {:error, reason} ->
        put_error(socket, :hours, message(:hours, reason))
    end
  end

  defp put_error(socket, field, nil),
    do:
      Component.assign(socket, :meeting_errors, Map.delete(socket.assigns.meeting_errors, field))

  defp put_error(socket, field, message),
    do:
      Component.assign(
        socket,
        :meeting_errors,
        Map.put(socket.assigns.meeting_errors, field, message)
      )

  # -------------------------------------------------------------------
  # Continue
  # -------------------------------------------------------------------

  @doc """
  Before Continue leaves the step: saves a change still pending (a name
  typed and never left), and reports whether the step is complete. A step
  with an error stays.
  """
  @spec continue(socket()) :: {:ok, socket()} | {:error, socket()}
  def continue(socket) do
    socket = socket |> validate_meeting() |> save_meeting()
    if invalid?(socket.assigns), do: {:error, socket}, else: {:ok, socket}
  end

  # -------------------------------------------------------------------
  # Wording
  # -------------------------------------------------------------------

  @doc "The names the suggestion chips fill in, in the host's language."
  @spec name_suggestions() :: [String.t()]
  def name_suggestions do
    [
      dgettext("onboarding_wizard", "Intro call"),
      dgettext("onboarding_wizard", "Consultation"),
      dgettext("onboarding_wizard", "Coaching session"),
      dgettext("onboarding_wizard", "Coffee chat")
    ]
  end

  defp message(:name, :required), do: dgettext("onboarding_wizard", "Give your meeting a name.")

  defp message(:name, :too_long),
    do:
      dgettext("onboarding_wizard", "Keep the name to %{count} characters or fewer.",
        count: MeetingSetup.name_max_length()
      )

  defp message(:duration_minutes, _error) do
    range = MeetingSetup.duration_range()

    dgettext(
      "onboarding_wizard",
      "Choose a length from %{min} to %{max} minutes, in steps of %{step}.",
      min: range.first,
      max: range.last,
      step: MeetingSetup.duration_step()
    )
  end

  defp message(:location, :video_unavailable),
    do:
      dgettext(
        "onboarding_wizard",
        "Your video connection isn't available any more. Choose another place, or reconnect it in Settings later."
      )

  defp message(:save, _error),
    do: dgettext("onboarding_wizard", "Your meeting couldn't be saved. Please try again.")

  defp message(:hours, :no_days), do: dgettext("onboarding_wizard", "Choose at least one day.")

  defp message(:hours, :end_before_start),
    do: dgettext("onboarding_wizard", "Choose an end time after the start time.")

  defp message(:hours, {:breaks_outside_hours, _breaks}),
    do:
      dgettext(
        "onboarding_wizard",
        "Some of your breaks fall outside these hours. Change them in your availability settings."
      )

  defp message(:hours, _error),
    do: dgettext("onboarding_wizard", "Your hours couldn't be saved. Please try again.")
end
