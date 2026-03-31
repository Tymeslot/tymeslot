defmodule Tymeslot.Integrations.Calendar.CalDAV.TierDetectorTest do
  use ExUnit.Case, async: true
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalDAV.TierDetector

  describe "xml_contains_sync_token?/1" do
    test "returns true when body contains 'sync-token'" do
      assert TierDetector.xml_contains_sync_token?(
               "<d:sync-token>http://example.com/1</d:sync-token>"
             )
    end

    test "returns true when body contains 'sync-collection'" do
      assert TierDetector.xml_contains_sync_token?(
               "<d:supported-report-set><d:sync-collection/></d:supported-report-set>"
             )
    end

    test "returns false when body contains neither sync keyword" do
      refute TierDetector.xml_contains_sync_token?("<d:multistatus><d:response/></d:multistatus>")
    end

    test "returns false for non-binary input" do
      refute TierDetector.xml_contains_sync_token?(nil)
      refute TierDetector.xml_contains_sync_token?(42)
      refute TierDetector.xml_contains_sync_token?([])
    end
  end

  describe "xml_contains_ctag?/1" do
    test "returns true when body contains 'getctag'" do
      assert TierDetector.xml_contains_ctag?("<cs:getctag>abc123</cs:getctag>")
    end

    test "returns false when body does not contain 'getctag'" do
      refute TierDetector.xml_contains_ctag?("<d:multistatus><d:response/></d:multistatus>")
    end

    test "returns false for non-binary input" do
      refute TierDetector.xml_contains_ctag?(nil)
      refute TierDetector.xml_contains_ctag?(42)
    end
  end
end
