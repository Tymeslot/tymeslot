defmodule Tymeslot.EmailTesting.Registry do
  @moduledoc """
  Registry of available email templates and helpers for parsing CLI specs.
  """

  @templates %{
    "1" => {:appointment_confirmation_organizer, "Appointment Confirmation (Organizer)"},
    "2" => {:appointment_confirmation_attendee, "Appointment Confirmation (Attendee)"},
    "3" => {:appointment_reminder_organizer, "Appointment Reminder (Organizer)"},
    "4" => {:appointment_reminder_attendee, "Appointment Reminder (Attendee)"},
    "5" => {:appointment_cancellation_organizer, "Appointment Cancellation (Organizer)"},
    "6" => {:appointment_cancellation_attendee, "Appointment Cancellation (Attendee)"},
    "7" => {:email_verification, "Email Verification"},
    "8" => {:password_reset, "Password Reset"},
    "9" => {:calendar_sync_error, "Calendar Sync Error"},
    "10" => {:contact_form, "Contact Form"},
    "11" => {:reschedule_request, "Reschedule Request"},
    "12" => {:email_change_verification, "Email Change Verification"},
    "13" => {:email_change_notification, "Email Change Notification"},
    "14" => {:email_change_confirmed, "Email Change Confirmed"}
  }

  @doc "Return the registry map of templates"
  @spec templates() :: map()
  def templates, do: @templates

  @doc "Return registry as a list sorted by numeric id"
  @spec list_sorted() :: list({String.t(), {atom(), String.t()}})
  def list_sorted do
    Enum.sort_by(@templates, fn {num, _} -> String.to_integer(num) end)
  end

  @doc "Parse a template spec (numbers or names, comma-separated) into numeric id strings"
  @spec parse_template_spec(String.t()) :: list(String.t())
  def parse_template_spec(spec) when is_binary(spec) do
    spec
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&normalize_template_id/1)
    |> Enum.filter(&(&1 != nil))
    |> Enum.uniq()
  end

  @doc "Normalize id input (numeric string or template atom name) to numeric id string"
  @spec normalize_template_id(String.t()) :: String.t() | nil
  def normalize_template_id(id) when is_binary(id) do
    cond do
      Map.has_key?(@templates, id) ->
        id

      match = Enum.find(@templates, fn {_, {key, _}} -> Atom.to_string(key) == id end) ->
        elem(match, 0)

      true ->
        nil
    end
  end
end
