defmodule TymeslotWeb.Helpers.FormErrorsTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  import Ecto.Changeset

  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Helpers.FormErrors

  @types %{name: :string, title: :string, count: :integer}

  defmodule Item do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :title, :string
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(item, attrs), do: item |> cast(attrs, [:title]) |> validate_required([:title])
  end

  defmodule Parent do
    use Ecto.Schema

    embedded_schema do
      field :label, :string
      embeds_many :items, Item
    end
  end

  defp changeset(attrs) do
    {%{}, @types}
    |> cast(attrs, Map.keys(@types))
    |> validate_required([:title])
    |> validate_length(:name, min: 3)
    |> validate_number(:count, greater_than: 0)
  end

  defp in_locale(locale, fun), do: Gettext.with_locale(TymeslotWeb.Gettext, locale, fun)

  describe "to_map/1" do
    test "interpolates every placeholder" do
      assert FormErrors.to_map(changeset(%{name: "ab", count: 0})) == %{
               title: ["can't be blank"],
               name: ["should be at least 3 character(s)"],
               count: ["must be greater than 0"]
             }
    end

    test "translates into the current locale" do
      errors = in_locale("de", fn -> FormErrors.to_map(changeset(%{name: "ab"})) end)

      assert errors.title == ["darf nicht leer sein"]
      assert errors.name == ["sollte mindestens 3 Zeichen lang sein"]
    end

    # The group rules are refused in the domain with an `errors` msgid; the
    # meeting type form shows them in the host's language like any other error.
    test "translates a domain refusal into the current locale" do
      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
          name: "Workshop",
          duration_minutes: 60,
          user_id: 1,
          max_participants: 5,
          requires_approval: true
        })

      errors = in_locale("de", fn -> FormErrors.to_map(changeset) end)

      assert "Gruppenbuchungen können keine Bestätigung erfordern" in errors.max_participants
    end

    # The domain's own messages (here a break outside the day's hours) are
    # registered in the errors domain like Ecto's, so they translate too.
    test "translates the domain's own changeset messages" do
      changeset =
        AvailabilityBreakSchema.changeset(
          %AvailabilityBreakSchema{},
          %{weekly_availability_id: 1, start_time: ~T[08:00:00], end_time: ~T[09:30:00]},
          work_hours: %{start_time: ~T[09:00:00], end_time: ~T[17:00:00], ends_next_day: false}
        )

      errors = in_locale("de", fn -> FormErrors.to_map(changeset) end)

      assert errors.start_time == ["muss innerhalb der Arbeitszeiten liegen"]
    end

    # A message translated where it is built (a length that carries its own
    # number) and a registered plural both reach the form translated.
    test "translates build-time messages and plurals" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        label =
          AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, %{
            weekly_availability_id: 1,
            start_time: ~T[12:00:00],
            end_time: ~T[13:00:00],
            label: String.duplicate("x", 200)
          })

        assert [length_message] = FormErrors.to_map(label).label
        assert length_message =~ ~r/^darf höchstens \d+ Zeichen lang sein$/

        reminders =
          MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
            name: "Call",
            duration_minutes: 30,
            user_id: 1,
            reminder_config: for(m <- [5, 10, 15, 20], do: %{value: m, unit: "minutes"})
          })

        assert FormErrors.to_map(reminders).reminder_config == [
                 "darf nicht mehr als 3 Erinnerungen enthalten"
               ]
      end)
    end

    test "is empty for a valid changeset" do
      assert FormErrors.to_map(changeset(%{title: "Valid"})) == %{}
    end
  end

  describe "first_per_field/1" do
    test "keeps each field's first message" do
      cs = add_error(changeset(%{name: "ab"}), :name, "is reserved")

      assert FormErrors.first_per_field(cs) == %{
               title: "can't be blank",
               name: "is reserved"
             }
    end
  end

  describe "first/2" do
    # Shown next to its field, the message stands alone: no field name made
    # up from the atom in English.
    test "is the first field's first message alone, without labels" do
      assert FormErrors.first(changeset(%{name: "ab", count: 0})) == "must be greater than 0"
      assert in_locale("de", fn -> FormErrors.first(changeset(%{})) end) == "darf nicht leer sein"
    end

    # For a flash, away from the field, the caller names it in the reader's
    # language.
    test "is prefixed with the field's label when the caller passes one" do
      message =
        in_locale("de", fn ->
          FormErrors.first(changeset(%{}), %{
            title: Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_common", "Title")
          })
        end)

      assert message == "Titel: darf nicht leer sein"
    end

    test "reaches a message nested under an embedded field" do
      cs =
        %Parent{}
        |> cast(%{label: "ok", items: [%{title: "fine"}, %{title: ""}]}, [:label])
        |> cast_embed(:items, with: &Item.changeset/2)

      assert FormErrors.first(cs) == "can't be blank"
    end

    test "is nil for a valid changeset" do
      assert FormErrors.first(changeset(%{title: "Valid"})) == nil
    end
  end
end
