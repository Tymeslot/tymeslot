defmodule Tymeslot.MeetingTypes.LocationOptionTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.MeetingTypes.LocationOption

  defp changeset(attrs, base \\ %LocationOption{}) do
    LocationOption.changeset(base, attrs)
  end

  defp errors(changeset), do: Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

  describe "changeset/2 identity" do
    test "generates an id when none is supplied" do
      cs = changeset(%{"kind" => "in_person", "label" => "The office"})

      assert cs.valid?
      assert {:ok, _uuid} = UUID.cast(Changeset.get_field(cs, :id))
    end

    test "keeps an id it was given, so a booking's recorded choice keeps resolving" do
      cs = changeset(%{"id" => "loc-1", "kind" => "in_person", "label" => "The office"})

      assert Changeset.get_field(cs, :id) == "loc-1"
    end

    test "requires a kind and a label" do
      cs = changeset(%{})

      refute cs.valid?
      assert %{kind: ["can't be blank"], label: ["can't be blank"]} = errors(cs)
    end

    test "rejects a kind outside the known set" do
      cs = changeset(%{"kind" => "hologram", "label" => "The holodeck"})

      refute cs.valid?
      assert %{kind: ["is invalid"]} = errors(cs)
    end
  end

  describe "changeset/2 kind-specific rules" do
    test "a video location must name an integration" do
      cs = changeset(%{"kind" => "video", "label" => "Zoom"})

      refute cs.valid?
      assert %{video_integration_ids: ["can't be blank"]} = errors(cs)
    end

    test "a video location naming an integration is valid" do
      cs = changeset(%{"kind" => "video", "label" => "Zoom", "video_integration_ids" => ["7"]})

      assert cs.valid?
      assert Changeset.get_field(cs, :video_integration_ids) == [7]
    end

    test "a video location keeps several integrations in order, each once" do
      cs =
        changeset(%{
          "kind" => "video",
          "label" => "Video call",
          "video_integration_ids" => ["9", "7", "9"]
        })

      assert cs.valid?
      assert Changeset.get_field(cs, :video_integration_ids) == [9, 7]
    end

    test "a phone location must publish a number or ask the booker for theirs" do
      cs = changeset(%{"kind" => "phone", "label" => "Phone call"})

      refute cs.valid?
      assert %{details: ["can't be blank"]} = errors(cs)
    end

    test "a phone location that asks the booker needs no number of its own" do
      cs =
        changeset(%{
          "kind" => "phone",
          "label" => "Phone call",
          "collect_from_guest" => "true"
        })

      assert cs.valid?
    end

    test "in-person and custom locations need nothing beyond a label" do
      assert changeset(%{"kind" => "in_person", "label" => "The office"}).valid?
      assert changeset(%{"kind" => "custom", "label" => "Somewhere else"}).valid?
    end

    test "rejects a label longer than the column allows" do
      cs = changeset(%{"kind" => "custom", "label" => String.duplicate("a", 121)})

      refute cs.valid?
      assert %{label: ["should be at most %{count} character(s)"]} = errors(cs)
    end
  end

  describe "changeset/2 kind changes" do
    test "demoting a video location drops the integration it pointed at" do
      video = %LocationOption{
        id: "loc-1",
        kind: "video",
        label: "Zoom",
        video_integration_ids: [7]
      }

      cs = changeset(%{"kind" => "in_person", "label" => "The office"}, video)

      assert cs.valid?
      assert Changeset.get_field(cs, :video_integration_ids) == []
    end

    test "leaving the phone kind drops the ask-the-booker flag" do
      phone = %LocationOption{
        id: "loc-1",
        kind: "phone",
        label: "Phone call",
        collect_from_guest: true
      }

      cs = changeset(%{"kind" => "custom", "label" => "Somewhere else"}, phone)

      assert cs.valid?
      assert Changeset.get_field(cs, :collect_from_guest) == false
    end

    test "details survive a kind change, because every kind means the same by them" do
      in_person = %LocationOption{
        id: "loc-1",
        kind: "in_person",
        label: "The office",
        details: "12 High Street"
      }

      cs = changeset(%{"kind" => "custom"}, in_person)

      assert Changeset.get_field(cs, :details) == "12 High Street"
    end

    test "an edit that does not change the kind keeps its config" do
      video = %LocationOption{
        id: "loc-1",
        kind: "video",
        label: "Zoom",
        video_integration_ids: [7]
      }

      cs = changeset(%{"label" => "Zoom (sales)"}, video)

      assert cs.valid?
      assert Changeset.get_field(cs, :video_integration_ids) == [7]
    end
  end

  describe "display/1" do
    test "is the label alone when there is nothing to add to it" do
      assert LocationOption.display(%LocationOption{label: "Zoom"}) == "Zoom"
      assert LocationOption.display(%LocationOption{label: "Zoom", details: ""}) == "Zoom"
    end

    test "reads as one place when details are present" do
      option = %LocationOption{label: "Our office", details: "12 High Street"}

      assert LocationOption.display(option) == "Our office (12 High Street)"
    end
  end
end
