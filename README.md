# 🛡️ Self-Updating Predictive Maintenance for Military Vehicle Powertrains

> Forecasting Remaining Useful Life (RUL) from sensor time-series — 
> built to stay accurate under real-world distribution shift.

## What This Project Does

This system predicts **when a military vehicle's engine will fail** based on 
its sensor data — but unlike a typical machine-learning study, it is designed 
to **keep predicting accurately for years**, automatically adapting as:

- 🚙 Vehicles age and components degrade
- 🎯 Mission profiles change  
- 🌍 Operating environments shift (climate, terrain, load)
- 📊 The underlying data distribution drifts

## Why This Matters

Most RUL models are trained once and deployed forever — and silently fail when 
the real world stops looking like the training set. This project tackles 
**distribution shift as a first-class problem**, not an afterthought.
