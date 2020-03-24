defmodule Ftp.Mixfile do
  use Mix.Project

  def project do
    [
      app: :se_ftp, #Due to naming collision with erlang's :ftp app we need to keep the name distinctive
      version: "0.1.0",
      elixir: "~> 1.4",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      erlc_paths: erlc_paths(Mix.env())
      # elixirc_options: [warnings_as_errors: true]
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [
      mod: applications(Mix.env()),
      extra_applications: [:logger, :ranch]
    ]
  end

  def applications(_) do
    {Ftp, []}
  end

  def erlc_paths(:test), do: ["src", "test/src"]
  def erlc_paths(_), do: ["src"]

  # Dependencies can be Hex packages:
  #
  #   {:my_dep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:my_dep, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [
      {:ranch, "~> 1.3.2"},
      {:fsm, "~> 0.3.0"},
      {:propcheck, "~> 1.0", only: [:dev, :test]},
      {:mix_test_watch, "~> 0.5", only: :dev, runtime: false}
    ]
  end
end
