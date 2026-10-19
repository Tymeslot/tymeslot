defmodule Tymeslot.MeetingTypes.InputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.InputValidation

  describe "validate_meeting_type_form/2" do
    test "accepts valid meeting type form" do
      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "description" => "A quick chat",
        "icon" => "hero-bolt",
        "meeting_mode" => "video"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["name"] == "Coffee Chat"
      assert sanitized["duration"] == "30"
      assert sanitized["icon"] == "hero-bolt"
    end

    # The placeholders carry the limits, in the host's language.
    test "refuses durations in the current locale, with their limits" do
      in_de = fn duration ->
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          InputValidation.validate_field(:duration, duration, %{})
        end)
      end

      assert {:error, %{duration: "Die Dauer muss mindestens 5 Minuten betragen"}} = in_de.("1")

      assert {:error, %{duration: "Die Dauer darf 24 Stunden (1440 Minuten) nicht überschreiten"}} =
               in_de.("1445")

      assert {:error, %{duration: "Die Dauer muss ein Vielfaches von 5 Minuten sein"}} =
               in_de.("17")
    end

    test "returns error for missing name" do
      params = %{"duration" => "30", "icon" => "hero-bolt", "meeting_mode" => "personal"}
      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :name)
    end

    test "returns error for missing duration" do
      params = %{"name" => "Coffee Chat", "icon" => "hero-bolt", "meeting_mode" => "personal"}
      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :duration)
    end

    test "returns error for invalid icon" do
      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "icon" => "not-a-real-icon",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :icon)
    end

    test "defaults icon to 'none' when nil" do
      params = %{"name" => "Chat", "duration" => "30", "meeting_mode" => "personal"}
      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["icon"] == "none"
    end

    test "accumulates multiple field errors" do
      params = %{}
      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :duration)
    end
  end

  describe "validate_meeting_type_form/2 - target calendar" do
    test "keeps a provider calendar id containing a double hyphen and a hex run" do
      # The id is matched against the integration's calendar list afterwards,
      # so a rewritten id refuses a calendar the organiser picked from it.
      calendar_id = "/dav/calendars/alice/work--0xabc/"

      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "icon" => "hero-bolt",
        "target_calendar_id" => calendar_id
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["target_calendar_id"] == calendar_id
    end
  end

  describe "validate_meeting_type_form/2 - duration constraints" do
    test "rejects duration below 5 minutes" do
      params = %{
        "name" => "Chat",
        "duration" => "4",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :duration)
    end

    test "rejects duration above 1440 minutes" do
      params = %{
        "name" => "Chat",
        "duration" => "1441",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :duration)
    end

    test "rejects duration not divisible by 5" do
      params = %{
        "name" => "Chat",
        "duration" => "17",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :duration)
    end

    test "accepts minimum valid duration (5 minutes)" do
      params = %{
        "name" => "Chat",
        "duration" => "5",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, _sanitized} = InputValidation.validate_meeting_type_form(params)
    end

    test "accepts maximum valid duration (1440 minutes)" do
      params = %{
        "name" => "Chat",
        "duration" => "1440",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, _sanitized} = InputValidation.validate_meeting_type_form(params)
    end
  end

  describe "validate_meeting_type_form/2 - slot_interval" do
    test "accepts a blank slot interval (means: same as meeting length)" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "slot_interval" => "",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["slot_interval"] == ""
    end

    test "accepts a missing slot interval (means: same as meeting length)" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["slot_interval"] == ""
    end

    test "accepts a valid slot interval" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "slot_interval" => "15",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["slot_interval"] == "15"
    end

    test "rejects a slot interval below 5 minutes" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "slot_interval" => "4",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert errors[:slot_interval] == "Slot interval must be at least 5 minutes"
    end

    test "rejects a slot interval above 480 minutes" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "slot_interval" => "481",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert errors[:slot_interval] == "Slot interval cannot exceed 480 minutes"
    end
  end

  describe "validate_meeting_type_form/2 - description" do
    test "accepts optional empty description" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "description" => ""
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["description"] == ""
    end

    test "rejects description exceeding 500 characters" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "description" => String.duplicate("a", 501)
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :description)
    end
  end

  describe "validate_meeting_type_form/2 - reminder_config" do
    test "accepts nil reminder_config" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "reminder_config" => nil
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["reminder_config"] == []
    end

    test "rejects more than 3 reminders" do
      reminders =
        Jason.encode!([
          %{"value" => 1, "unit" => "hours"},
          %{"value" => 2, "unit" => "hours"},
          %{"value" => 3, "unit" => "hours"},
          %{"value" => 4, "unit" => "hours"}
        ])

      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "reminder_config" => reminders
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :reminder_config)
    end

    test "rejects duplicate reminders" do
      reminders =
        Jason.encode!([
          %{"value" => 1, "unit" => "hours"},
          %{"value" => 1, "unit" => "hours"}
        ])

      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "reminder_config" => reminders
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :reminder_config)
    end
  end

  describe "validate_meeting_type_form/2 - names that produce empty slugs" do
    test "rejects name consisting only of special characters" do
      params = %{
        "name" => "!!!",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert errors.name =~ "at least one letter or number"
    end

    test "rejects name consisting only of punctuation" do
      params = %{
        "name" => "....",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert errors.name =~ "at least one letter or number"
    end
  end

  describe "validate_field/3 for :max_participants" do
    test "accepts a limit inside the range" do
      assert {:ok, "25"} = InputValidation.validate_field(:max_participants, "25", %{})
    end

    test "accepts the solo default of 1" do
      assert {:ok, "1"} = InputValidation.validate_field(:max_participants, "1", %{})
    end

    test "rejects a limit above 999" do
      assert {:error, %{max_participants: "Participant limit cannot exceed 999"}} =
               InputValidation.validate_field(:max_participants, "1500", %{})
    end

    test "rejects zero" do
      assert {:error, %{max_participants: "Participant limit must be at least 1"}} =
               InputValidation.validate_field(:max_participants, "0", %{})
    end

    test "rejects a non-numeric value" do
      assert {:error, %{max_participants: "Participant limit must be a valid number"}} =
               InputValidation.validate_field(:max_participants, "lots", %{})
    end
  end

  describe "validate_meeting_type_form/2 with max_participants" do
    test "sanitises max_participants when present" do
      params = %{
        "name" => "Group Demo",
        "duration" => "30",
        "icon" => "hero-bolt",
        "meeting_mode" => "personal",
        "max_participants" => "10"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["max_participants"] == "10"
    end

    test "returns an error for an out-of-range max_participants" do
      params = %{
        "name" => "Group Demo",
        "duration" => "30",
        "icon" => "hero-bolt",
        "meeting_mode" => "personal",
        "max_participants" => "1000"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :max_participants)
    end

    test "omits max_participants from sanitised params when absent" do
      params = %{
        "name" => "Solo Chat",
        "duration" => "30",
        "icon" => "hero-bolt",
        "meeting_mode" => "personal"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      refute Map.has_key?(sanitized, "max_participants")
    end

    # The canonical param is how the form says "this type is solo", so 1 is
    # a legitimate value here even though the group input rejects it.
    test "accepts a canonical max_participants of 1 for a solo type" do
      params = %{
        "name" => "Solo Chat",
        "duration" => "30",
        "icon" => "hero-bolt",
        "meeting_mode" => "personal",
        "max_participants" => "1"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["max_participants"] == "1"
    end
  end

  describe "validate_field/3 for the group participant limit" do
    # The visible input only exists while group bookings are switched on, so
    # 1 is not a small group — it is the toggle being off. Accepting it there
    # silently stored a solo type behind an enabled toggle, stranding any
    # bookings already taken on the slot.
    test "rejects a limit of 1" do
      assert {:error, %{max_participants: message}} =
               InputValidation.validate_field(:group_participants, "1", %{})

      assert message =~ "at least 2"
    end

    test "accepts the smallest real group" do
      assert {:ok, "2"} = InputValidation.validate_field(:group_participants, "2", %{})
    end

    test "still rejects values above the maximum" do
      assert {:error, %{max_participants: _message}} =
               InputValidation.validate_field(:group_participants, "1000", %{})
    end

    test "rejects a non-numeric limit" do
      assert {:error, %{max_participants: message}} =
               InputValidation.validate_field(:group_participants, "abc", %{})

      assert message =~ "valid number"
    end
  end
end
