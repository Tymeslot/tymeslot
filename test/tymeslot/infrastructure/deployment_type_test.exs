defmodule Tymeslot.Infrastructure.DeploymentTypeTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.DeploymentType

  describe "normalise/1" do
    test "recognises cloudron" do
      assert DeploymentType.normalise("cloudron") == "cloudron"
    end

    test "maps the legacy main to cloudron" do
      assert DeploymentType.normalise("main") == "cloudron"
    end

    test "falls back to docker for anything else, unset included" do
      for raw <- [nil, "", "docker", "railway", "Cloudron"] do
        assert {raw, DeploymentType.normalise(raw)} == {raw, "docker"}
      end
    end
  end
end
