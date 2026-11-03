defmodule TymeslotWeb.OnboardingLive.StepConfig do
  @moduledoc """
  The onboarding steps and their display configuration:
  profile → connect_calendar → meeting → choose_theme → ready.

  The sequence is fixed. Where a host may enter it is not: `resume_step/1`
  derives the first incomplete step from the account itself, and no step
  after that one can be reached, so the meeting and theme steps are never
  shown to a host without a bookable calendar.
  """

  @typedoc "Represents an onboarding step in the flow."
  @type step :: :profile | :connect_calendar | :meeting | :choose_theme | :ready

  @typedoc "A step a host can resume at: the first one their account has not done."
  @type resume_step :: :profile | :connect_calendar | :meeting

  @typedoc "The account state `resume_step/1` reads."
  @type account_state :: %{username: String.t() | nil, bookable_calendar?: boolean()}

  use Gettext, backend: TymeslotWeb.Gettext

  @steps [:profile, :connect_calendar, :meeting, :choose_theme, :ready]

  # String forms of the same list, so a URL segment can be checked without
  # converting user-supplied text into an atom.
  @step_names Enum.map(@steps, &Atom.to_string/1)

  # -------------------------------------------------------------------
  # Step flow
  # -------------------------------------------------------------------

  @doc "Returns the onboarding step sequence."
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc "Returns the total number of steps."
  @spec step_count() :: pos_integer()
  def step_count, do: length(@steps)

  @doc "Returns the 1-indexed position of a step."
  @spec step_number(step()) :: pos_integer()
  def step_number(step), do: (index(step) || 0) + 1

  @doc """
  Returns the step a host enters onboarding at, derived from their account:
  without a username they start at the link; without a bookable calendar, at
  the calendar; otherwise at the meeting.
  """
  @spec resume_step(account_state()) :: resume_step()
  def resume_step(%{username: username}) when username in [nil, ""], do: :profile
  def resume_step(%{bookable_calendar?: false}), do: :connect_calendar
  def resume_step(%{bookable_calendar?: true}), do: :meeting

  @doc """
  Whether a host who resumes at `resume_step` may open `step`. A step past
  the link or the calendar depends on it, so it stays out of reach until that
  is done. The meeting is the last step the account can show as unfinished,
  so a host who resumes there may open any step.
  """
  @spec reachable?(step(), resume_step()) :: boolean()
  def reachable?(_step, :meeting), do: true
  def reachable?(step, resume_step), do: step_number(step) <= step_number(resume_step)

  @doc """
  Validates if a given step name is one of the known steps.
  """
  @spec valid_step?(term()) :: boolean()
  def valid_step?(step_name) when is_binary(step_name), do: step_name in @step_names
  def valid_step?(step_atom) when is_atom(step_atom), do: step_atom in @steps
  def valid_step?(_other), do: false

  @doc """
  Checks if a step comes before the current one.
  """
  @spec step_completed?(step(), step()) :: boolean()
  def step_completed?(step, current_step) do
    with index when is_integer(index) <- index(step),
         current when is_integer(current) <- index(current_step) do
      index < current
    else
      _nil -> false
    end
  end

  @doc """
  Returns the next step, or nil if at the end.
  """
  @spec next_step(step()) :: step() | nil
  def next_step(step), do: neighbour(step, 1)

  @doc """
  Returns the previous step, or nil if at the beginning.
  """
  @spec previous_step(step()) :: step() | nil
  def previous_step(step), do: neighbour(step, -1)

  defp neighbour(step, delta) do
    case index(step) do
      nil -> nil
      index when index + delta < 0 -> nil
      index -> Enum.at(@steps, index + delta)
    end
  end

  defp index(step), do: Enum.find_index(@steps, &(&1 == step))

  # -------------------------------------------------------------------
  # Step display
  # -------------------------------------------------------------------

  @doc """
  Returns the step title for display purposes.
  """
  @spec step_title(step()) :: String.t()
  def step_title(:profile), do: dgettext("onboarding_wizard", "Your link")
  def step_title(:connect_calendar), do: dgettext("onboarding_wizard", "Your calendar")
  def step_title(:meeting), do: dgettext("onboarding_wizard", "Your meeting")
  def step_title(:choose_theme), do: dgettext("onboarding_wizard", "Your look")
  def step_title(:ready), do: dgettext("onboarding_wizard", "You're live")

  @doc """
  Returns the step title, given whether the booking page is live. Only the
  final step reads differently: a page that refuses visitors is not live, so
  it says so.
  """
  @spec step_title(step(), boolean() | nil) :: String.t()
  def step_title(:ready, false), do: dgettext("onboarding_wizard", "Almost live")
  def step_title(step, _booking_page_live), do: step_title(step)

  @doc """
  Returns the short label the progress indicator shows for a step.
  """
  @spec progress_label(step()) :: String.t()
  def progress_label(:profile), do: dgettext("onboarding_wizard", "Link")
  def progress_label(:connect_calendar), do: dgettext("onboarding_wizard", "Calendar")
  def progress_label(:meeting), do: dgettext("onboarding_wizard", "Meeting")
  def progress_label(:choose_theme), do: dgettext("onboarding_wizard", "Look")
  def progress_label(:ready), do: dgettext("onboarding_wizard", "Live")

  @doc """
  Returns the step description for display purposes.
  """
  @spec step_description(step()) :: String.t()
  def step_description(:profile),
    do:
      dgettext(
        "onboarding_wizard",
        "This is the link people will use to book you."
      )

  def step_description(:connect_calendar),
    do:
      dgettext(
        "onboarding_wizard",
        "Sync your calendar to avoid double-bookings and keep everything in one place."
      )

  def step_description(:choose_theme),
    do:
      dgettext(
        "onboarding_wizard",
        "Pick a look and watch your page change."
      )

  def step_description(:meeting),
    do: dgettext("onboarding_wizard", "Decide what people book with you and for how long.")

  def step_description(:ready),
    do:
      dgettext(
        "onboarding_wizard",
        "Your page is ready for bookings. Try it yourself, then send it to someone."
      )

  @doc """
  Returns the step description, given whether the booking page is live. Only
  the final step reads differently: it cannot ask the host to share a page
  that refuses visitors, and says nothing while that is not known yet (`nil`,
  on the disconnected render).
  """
  @spec step_description(step(), boolean() | nil) :: String.t()
  def step_description(:ready, nil), do: ""

  def step_description(:ready, false),
    do:
      dgettext(
        "onboarding_wizard",
        "Your link is ready, but the page only goes live once a calendar is connected."
      )

  def step_description(step, _booking_page_live), do: step_description(step)

  @doc """
  Returns the button text for the next step.
  """
  @spec next_button_text(step()) :: String.t()
  def next_button_text(:ready), do: dgettext("onboarding_wizard", "Go to dashboard")
  def next_button_text(_step), do: dgettext("onboarding_wizard", "Continue")

  @doc """
  Returns the variant of the next button. On the final step the share actions
  lead, so finishing is a secondary action.
  """
  @spec next_button_variant(step()) :: :primary | :secondary
  def next_button_variant(:ready), do: :secondary
  def next_button_variant(_step), do: :primary

  @doc """
  Returns whether the back button should be shown for a given step.
  """
  @spec show_back_button?(step()) :: boolean()
  def show_back_button?(:profile), do: false
  def show_back_button?(:ready), do: false
  def show_back_button?(_step), do: true
end
