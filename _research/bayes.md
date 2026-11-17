---
title: Bayesian Modelings
order: 4
image: /assets/images/research/bayes.jpg
description: "Bayesian quantile models for space and survival, fast enough for real data."
summary: >-
  We build Bayesian quantile models for data spread over space and for
  survival outcomes, with fast variational methods so they scale to thousands
  of sites.
---

Bayesian models give honest uncertainty, but they can be slow. The usual asymmetric Laplace likelihood for quantile regression also fixes the shape of the errors once the quantile level is chosen. We use a more flexible error distribution and fit it with variational inference, so a spatial model with thousands of sites runs in minutes.

The same tools carry over to survival and causal questions, where flexible priors avoid strong shape assumptions.
