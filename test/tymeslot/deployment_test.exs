defmodule Tymeslot.DeploymentTest do
  use ExUnit.Case
  alias Tymeslot.Deployment

  describe "type/0" do
    test "returns :main when DEPLOYMENT_TYPE is set to main" do
      System.put_env("DEPLOYMENT_TYPE", "main")
      assert Deployment.type() == :main
    end

    test "returns :cloudron when DEPLOYMENT_TYPE is set to cloudron" do
      System.put_env("DEPLOYMENT_TYPE", "cloudron")
      assert Deployment.type() == :cloudron
    end

    test "returns :docker when DEPLOYMENT_TYPE is set to docker" do
      System.put_env("DEPLOYMENT_TYPE", "docker")
      assert Deployment.type() == :docker
    end

    test "returns nil when DEPLOYMENT_TYPE is not set" do
      System.delete_env("DEPLOYMENT_TYPE")
      assert Deployment.type() == nil
    end
  end

  describe "deployment type checking functions" do
    test "main?/0 returns true only for main deployment" do
      System.put_env("DEPLOYMENT_TYPE", "main")
      assert Deployment.main?() == true

      System.put_env("DEPLOYMENT_TYPE", "cloudron")
      assert Deployment.main?() == false
    end

    test "cloudron?/0 returns true only for cloudron deployment" do
      System.put_env("DEPLOYMENT_TYPE", "cloudron")
      assert Deployment.cloudron?() == true

      System.put_env("DEPLOYMENT_TYPE", "main")
      assert Deployment.cloudron?() == false
    end

    test "docker?/0 returns true only for docker deployment" do
      System.put_env("DEPLOYMENT_TYPE", "docker")
      assert Deployment.docker?() == true

      System.put_env("DEPLOYMENT_TYPE", "main")
      assert Deployment.docker?() == false
    end

    test "self_hosted?/0 returns true for both cloudron and docker" do
      System.put_env("DEPLOYMENT_TYPE", "cloudron")
      assert Deployment.self_hosted?() == true

      System.put_env("DEPLOYMENT_TYPE", "docker")
      assert Deployment.self_hosted?() == true

      System.put_env("DEPLOYMENT_TYPE", "main")
      assert Deployment.self_hosted?() == false
    end
  end
end
