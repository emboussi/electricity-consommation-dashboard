CREATE TABLE IF NOT EXISTS monitoring.e02_kpi_horaire (
  device_id TEXT NOT NULL,
  heure_debut TIMESTAMPTZ NOT NULL,
  heure_fin TIMESTAMPTZ NOT NULL,
  -- Groupe 1 : completude temporelle
  expected_seconds INT NOT NULL,
  observed_seconds INT NOT NULL,
  missing_seconds INT NOT NULL,
  multiple_seconds INT NOT NULL,
  completeness_pct NUMERIC(5,2) NOT NULL,
  -- Groupe 2 : cadence (gaps en secondes entre cycles reussis)
  gap_p50_s NUMERIC(8,2), gap_p95_s NUMERIC(8,2), gap_p99_s NUMERIC(8,2), gap_max_s NUMERIC(8,2),
  gaps_sup_2s INT, gaps_sup_5s INT, gaps_sup_60s INT,
  -- Groupe 3 : presence des variables
  cycles_complets INT, cycles_incomplets INT,
  -- Groupe 4 : fraicheurs SEPAREES (fenetre historique vs live)
  window_last_observed_at TIMESTAMPTZ,
  window_end_lag_s NUMERIC(8,1),
  current_latest_observed_at TIMESTAMPTZ,
  current_freshness_s NUMERIC(8,1),
  calcule_le TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, heure_debut)
);
