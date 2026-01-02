defmodule Tymeslot.Deployment do
  @moduledoc """
  Module for handling deployment-specific configuration and behavior.

  This module provides functions to check the deployment type (main, cloudron, docker)
  and make decisions based on it.
  """

  @doc """
  Gets the current deployment type from environment variable.

  Returns one of: :main, :cloudron, :docker, or nil if not set.
  """
  @spec type() :: :main | :cloudron | :docker | nil
  def type do
    case System.get_env("DEPLOYMENT_TYPE") do
      "main" -> :main
      "cloudron" -> :cloudron
      "docker" -> :docker
      _ -> nil
    end
  end

  @doc """
  Checks if the current deployment is the main SaaS deployment.
  """
  @spec main?() :: boolean()
  def main?, do: type() == :main

  @doc """
  Checks if the current deployment is a Cloudron deployment.
  """
  @spec cloudron?() :: boolean()
  def cloudron?, do: type() == :cloudron

  @doc """
  Checks if the current deployment is a Docker self-hosted deployment.
  """
  @spec docker?() :: boolean()
  def docker?, do: type() == :docker

  @doc """
  Checks if the current deployment is self-hosted (either Cloudron or Docker).
  """
  @spec self_hosted?() :: boolean()
  def self_hosted?, do: cloudron?() || docker?()
end
