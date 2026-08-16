defmodule Tymeslot.Integrations.Calendar.SyncLink.WriteEtagTest do
  @moduledoc """
  What the engine may read as a placeholder's etag out of a landed write.

  This is the one place that decides whether the three etag-based conflict kinds
  can fire at all, so it is pinned per shape rather than per provider: the module
  never asks which provider answered, and a provider that changes its response
  shape has to change one of these shapes to reach it.

  The absent cases carry as much weight as the present ones. `nil` is the answer
  that switches the etag-based kinds off for a provider, and it has to be
  reachable from every shape that carries no etag — not just from the ones
  somebody thought of.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :sync_links

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteEtag

  describe "from a write response" do
    test "reads Google's top-level etag off the raw response" do
      # The shape `handle_api_call/2` holds before `convert_event/1` narrows it:
      # the decoded JSON body, string-keyed, exactly as the API module answers.
      assert WriteEtag.extract(%{"etag" => "\"3573625707763998\"", "id" => "abc"}) ==
               "3573625707763998"
    end

    test "strips the quotes Google embeds in the value" do
      # Google sends the etag as an HTTP entity tag, quotes included. The cache
      # column it is compared against is populated by the inbound sync, which
      # cleans them, so storing the raw form would make every comparison unequal
      # and every pass a conflict.
      assert WriteEtag.extract(%{"etag" => "\"12345\""}) == "12345"
    end

    test "reads Outlook's @odata.etag through the same cleaner the cache uses" do
      # Graph sends a weak entity tag, `W/"abc123"`. `clean_etag/1` trims quotes
      # from both ends, so the inner quote after `W/` survives and the trailing
      # one does not — an asymmetric result, and deliberately not corrected
      # here. The value's only job is to compare equal to the cache's `etag`
      # column, which the inbound sync populates through that same function; a
      # cleaner normalisation on this side alone would make a matching pair
      # compare unequal and turn every pass into a conflict. The two sides have
      # to agree more than either has to be tidy.
      assert WriteEtag.extract(%{"@odata.etag" => "W/\"abc123\""}) ==
               EventProcessor.clean_etag("W/\"abc123\"")
    end

    test "reads an atom-keyed etag" do
      # The CalDAV family and the demo provider describe events with atom keys.
      assert WriteEtag.extract(%{etag: "\"caldav-etag\""}) == "caldav-etag"
    end

    test "answers nil for a response carrying no etag at all" do
      # Every OAuth `convert_event/1` produces exactly this: no etag key. A
      # provider whose write response is narrowed before it reaches here must
      # record no baseline rather than a wrong one.
      assert WriteEtag.extract(%{uid: "abc", summary: "Busy"}) == nil
    end

    test "answers nil for CalDAV's bare :ok" do
      assert WriteEtag.extract(:ok) == nil
    end

    test "answers nil for a create's {:ok, uid} and an update's {:ok, event}" do
      assert WriteEtag.extract({:ok, %{"etag" => "\"from-tuple\""}}) == "from-tuple"
      assert WriteEtag.extract({:ok, "just-a-uid"}) == nil
    end

    test "answers nil rather than an empty string for a blank etag" do
      # A provider sending `""`, or `""""`, has reported no etag. Storing the
      # empty string would make it a baseline that can never equal a real one,
      # so every subsequent pass would read a divergence that is not there.
      assert WriteEtag.extract(%{"etag" => ""}) == nil
      assert WriteEtag.extract(%{"etag" => "\"\""}) == nil
      assert WriteEtag.extract(%{"etag" => "   "}) == nil
    end

    test "answers nil for a non-binary etag" do
      assert WriteEtag.extract(%{"etag" => 12_345}) == nil
      assert WriteEtag.extract(%{"etag" => nil}) == nil
    end

    test "prefers the string key over the atom key when a shape carries both" do
      # The raw provider body is the authority: an atom-keyed etag on the same
      # map is our own conversion of an earlier read, which describes the event
      # before this write rather than after it.
      assert WriteEtag.extract(%{"etag" => "\"raw\"", etag: "converted"}) == "raw"
    end
  end
end
