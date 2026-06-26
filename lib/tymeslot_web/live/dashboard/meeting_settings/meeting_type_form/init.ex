defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Init do
  @moduledoc "Initialisation and form data building for MeetingTypeForm."

  alias Phoenix.Component
  alias Tymeslot.Features
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Utils.ReminderUtils

  @doc """
  Initialises the socket from the assigned meeting type on first render.

  A no-op when the socket is already initialised (guarded by `:__initialized__`).
  """
  @spec maybe_initialize(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_initialize(%{assigns: %{__initialized__: true}} = socket), do: socket

  def maybe_initialize(%{assigns: assigns} = socket) do
    type = Map.get(assigns, :type)

    socket
    |> Component.assign(:selected_icon, get_selected_icon(type))
    |> Component.assign(:meeting_mode, get_meeting_mode(type))
    |> Component.assign(:selected_video_integration_id, get_video_integration_id(type))
    |> Component.assign(
      :selected_calendar_integration_id,
      get_calendar_integration_id(type)
    )
    |> Component.assign(:selected_target_calendar_id, get_target_calendar_id(type))
    |> Component.assign(:reminders, get_reminders(type))
    |> Component.assign(:custom_fields, get_custom_fields(type))
    |> Component.assign(:allow_guests, get_allow_guests(type))
    |> Component.assign(:show_as_free, get_show_as_free(type))
    |> assign_payment_state(type, Map.get(assigns, :current_user))
    |> then(fn socket ->
      if id = socket.assigns.selected_calendar_integration_id do
        Component.assign(
          socket,
          :available_calendars,
          fetch_available_calendars(id, socket.assigns.calendar_integrations)
        )
      else
        socket
      end
    end)
    |> Component.assign(:form_data, build_form_data(type))
    |> Component.assign(:__initialized__, true)
  end

  @doc """
  Assigns the payments-section gating state and form values.

  Gating mirrors the payments dashboard: the section is only active when
  the `:meeting_payments` feature is enabled *and* the host's Stripe
  Connect account can accept charges. When the feature is off entirely the
  section is hidden; when it is on but Stripe is not yet connected the
  toggle renders disabled with a link to connect Stripe.
  """
  @spec assign_payment_state(
          Phoenix.LiveView.Socket.t(),
          Ecto.Schema.t() | nil,
          map() | nil
        ) :: Phoenix.LiveView.Socket.t()
  def assign_payment_state(socket, type, current_user) do
    feature_enabled? = payments_feature_enabled?(current_user)
    charges_enabled? = feature_enabled? and charges_enabled?(current_user)
    currency = host_currency(current_user)

    socket
    |> Component.assign(:payments_feature_enabled, feature_enabled?)
    |> Component.assign(:payments_charges_enabled, charges_enabled?)
    |> Component.assign(:payment_currency, currency)
    |> Component.assign(
      :payment_currency_minimum_cents,
      MeetingPayments.currency_minimum_cents(currency)
    )
    |> Component.assign(:payment_required, get_payment_required(type))
    |> Component.assign(:payment_price, get_payment_price(type))
  end

  defp payments_feature_enabled?(%{id: user_id}) do
    case Features.check_access(user_id, :meeting_payments) do
      :ok -> true
      {:error, :stripe_required} -> true
      _other -> false
    end
  end

  defp payments_feature_enabled?(_user), do: false

  defp charges_enabled?(%{id: user_id}), do: MeetingPayments.charges_enabled_for_user?(user_id)
  defp charges_enabled?(_user), do: false

  defp host_currency(%{id: user_id}) do
    case MeetingPayments.get_connect_account_for_user(user_id) do
      %{default_currency: currency} when is_binary(currency) and currency != "" ->
        currency

      _other ->
        List.first(MeetingPayments.currency_allowlist()) || "usd"
    end
  end

  defp host_currency(_user), do: List.first(MeetingPayments.currency_allowlist()) || "usd"

  @doc "Returns whether payment is required for an existing meeting type."
  @spec get_payment_required(Ecto.Schema.t() | nil) :: boolean()
  def get_payment_required(%{payment_required: true}), do: true
  def get_payment_required(_type), do: false

  @doc """
  Returns the major-unit price string for an existing meeting type's
  `price_cents`, or an empty string when unset.
  """
  @spec get_payment_price(Ecto.Schema.t() | nil) :: String.t()
  def get_payment_price(%{price_cents: cents}) when is_integer(cents) do
    :erlang.float_to_binary(cents / 100, decimals: 2)
  end

  def get_payment_price(_type), do: ""

  @doc "Builds the initial form data map from an existing meeting type or nil."
  @spec build_form_data(Ecto.Schema.t() | nil) :: map()
  def build_form_data(nil) do
    %{"name" => "", "duration" => "30", "description" => "", "icon" => "none"}
  end

  def build_form_data(type) do
    %{
      "name" => type.name || "",
      "duration" => to_string(type.duration_minutes || 30),
      "description" => type.description || "",
      "icon" => type.icon || "none"
    }
  end

  @doc "Returns whether guests are allowed for an existing meeting type."
  @spec get_allow_guests(Ecto.Schema.t() | nil) :: boolean()
  def get_allow_guests(%{allow_guests: true}), do: true
  def get_allow_guests(_type), do: false

  @spec get_show_as_free(Ecto.Schema.t() | nil) :: boolean()
  def get_show_as_free(%{show_as_free: true}), do: true
  def get_show_as_free(_type), do: false

  @doc "Returns the selected icon for a meeting type, or `\"none\"` when absent."
  @spec get_selected_icon(Ecto.Schema.t() | nil) :: String.t()
  def get_selected_icon(nil), do: "none"
  def get_selected_icon(%{icon: icon}) when is_binary(icon) and icon != "", do: icon
  def get_selected_icon(_arg), do: "none"

  @doc "Returns the meeting mode string for a meeting type."
  @spec get_meeting_mode(Ecto.Schema.t() | nil) :: String.t()
  def get_meeting_mode(%{allow_video: true}), do: "video"
  def get_meeting_mode(_arg), do: "personal"

  @doc "Returns the video integration id as an integer, or nil."
  @spec get_video_integration_id(Ecto.Schema.t() | nil) :: integer() | nil
  def get_video_integration_id(nil), do: nil
  def get_video_integration_id(%{video_integration_id: nil}), do: nil
  def get_video_integration_id(%{video_integration_id: id}) when is_integer(id), do: id

  def get_video_integration_id(%{video_integration_id: id}) when is_binary(id) do
    case Integer.parse(id) do
      {int, _value} -> int
      :error -> nil
    end
  end

  def get_video_integration_id(_arg), do: nil

  @doc "Returns the calendar integration id for a meeting type, or nil."
  @spec get_calendar_integration_id(Ecto.Schema.t() | nil) :: integer() | nil
  def get_calendar_integration_id(nil), do: nil
  def get_calendar_integration_id(%{calendar_integration_id: nil}), do: nil
  def get_calendar_integration_id(%{calendar_integration_id: id}), do: id

  @doc "Returns the target calendar id for a meeting type, or nil."
  @spec get_target_calendar_id(Ecto.Schema.t() | nil) :: String.t() | nil
  def get_target_calendar_id(nil), do: nil
  def get_target_calendar_id(%{target_calendar_id: nil}), do: nil
  def get_target_calendar_id(%{target_calendar_id: id}), do: id

  @doc """
  Fetches the calendars the user may pick as the meeting type's target.

  Only calendars the user has marked `selected: true` in the integration
  settings are returned — deselected calendars must not appear here, since
  the integration-level toggle is the single source of truth for which
  calendars the app may write to or read from.
  """
  @spec fetch_available_calendars(integer(), list()) :: list()
  def fetch_available_calendars(integration_id, integrations) do
    case Enum.find(integrations, &(&1.id == integration_id)) do
      nil -> []
      integration -> Selection.selected_calendars(integration.calendar_list)
    end
  end

  @doc "Returns the normalised reminders list for a meeting type."
  @spec get_reminders(Ecto.Schema.t() | nil) :: list()
  def get_reminders(nil), do: [%{value: 30, unit: "minutes"}]

  def get_reminders(%{reminder_config: reminders}) when is_list(reminders) do
    Enum.flat_map(reminders, fn r ->
      case ReminderUtils.normalize_reminder(r) do
        {:ok, reminder} -> [reminder]
        _other -> []
      end
    end)
  end

  def get_reminders(_arg), do: [%{value: 30, unit: "minutes"}]

  @doc "Returns the custom_fields list from an existing meeting type, or an empty list."
  @spec get_custom_fields(Ecto.Schema.t() | nil) :: list()
  def get_custom_fields(nil), do: []

  def get_custom_fields(%{custom_fields: fields}) when is_list(fields) do
    Enum.sort_by(fields, & &1.position)
  end

  def get_custom_fields(_arg), do: []
end
