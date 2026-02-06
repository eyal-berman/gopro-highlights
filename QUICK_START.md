# Quick Start Guide

## TL;DR - What To Do Now

### 1. Add Files to Xcode (5 min)

```bash
# Open the project
open "GoPro Highlight/GoPro Highlight.xcodeproj"
```

Then in Xcode:
- Right-click "GoPro Highlight" folder → "Add Files to..."
- Select: App, Models, ViewModels, Views, Services folders
- Settings: ✅ Create groups, ❌ Uncheck "Copy items"
- Click "Add"

### 2. Integrate GPMF Parser (15 min)

In Xcode:
```
File → Add Package Dependencies...
URL: https://github.com/gopro/gpmf-parser
```

OR manually:
```bash
cd /Users/eyalberman/dev/personal/gopro-v2
git submodule add https://github.com/gopro/gpmf-parser.git External/gpmf-parser
```

See `README.md` Step 2 for detailed instructions.

### 3. Build & Test (5 min)

- Build: ⌘B
- Run: ⌘R
- Select folder with GoPro videos
- Click "Start Processing"
- Check output in `[folder]/GoPro_Output/`

---

## What's Been Built

✅ **Complete macOS App** with:
- Beautiful 3-tab UI (Videos, Settings, Processing)
- Highlight extraction (configurable timing)
- Speed analysis (smart anomaly detection)
- Max speed videos (top N selection)
- Speed gauge overlay (customizable)
- Date/time overlay (customizable)
- Ski piste identification (OpenStreetMap)
- Video stitching
- CSV reports
- Real-time progress tracking

📁 **19 Swift Files** across:
- 3 Models
- 2 ViewModels
- 5 Views
- 8 Services
- 1 App entry point

🎯 **Architecture**:
- MVVM + Services
- Swift 6 async/await
- Actor-based concurrency
- AVFoundation video processing

---

## Files Reference

### Must Add to Xcode

All these exist on disk, just need to be added to Xcode project:

```
✅ App/GoPro_HighlightApp.swift
✅ Models/GoProVideo.swift
✅ Models/ExportSettings.swift
✅ Models/ProcessingProgress.swift
✅ ViewModels/VideoProcessorViewModel.swift
✅ ViewModels/SettingsViewModel.swift
✅ Views/Main/ContentView.swift
✅ Views/Settings/*.swift (4 files)
✅ Services/GPMF/GPMFParserService.swift
✅ Services/Video/*.swift (3 files)
✅ Services/Analysis/*.swift (3 files)
```

### Documentation

- `README.md` - Complete setup guide (444 lines)
- `NEXT_STEPS.md` - Detailed implementation summary
- `QUICK_START.md` - This file
- `~/.claude/plans/misty-dreaming-dawn.md` - Original plan

---

## Features Overview

### Basic Workflow
1. Select folder with GoPro videos
2. Configure settings (or use defaults)
3. Click "Start Processing"
4. Get output: clips + CSV report

### Highlight Extraction
- Before: 5s (default, configurable)
- After: 10s (default, configurable)
- Auto-merge overlapping segments
- Individual or stitched output

### Max Speed Videos
- Top N selection (default: 3)
- Separate before/after timing
- Optional overlay

### Overlays
**Speed Gauge:**
- Styles: semi-circular, full-circular, linear
- Units: km/h or mph
- Position: 5 locations
- Opacity: 30-100%

**Date/Time:**
- Formats: 4 options
- Font: 12-72pt
- Position: 5 locations
- Opacity: 30-100%

### CSV Report
Columns: Filename, Max Speed, Max Speed Time, Avg Speed, Highlights Count, Duration, File Size, Ski Piste, Resort

---

## Current Status

| Component | Status |
|-----------|--------|
| UI | ✅ Complete |
| Models | ✅ Complete |
| ViewModels | ✅ Complete |
| Services | ✅ Complete |
| GPMF Parser | 🟡 Mock (needs integration) |
| Testing | ⏸️ Ready when parser added |
| Distribution | ⏸️ Ready for DMG creation |

---

## Troubleshooting

**"Cannot find type 'GoProVideo' in scope"**
→ Files not added to Xcode. See Step 1 above.

**"Missing GPMF_parser.h"**
→ GPMF library not integrated. See Step 2 above.

**"No videos found"**
→ Folder doesn't contain .mp4/.MP4 files.

**"No GPMF metadata"**
→ Videos not from GoPro (Hero 5+), or parser not integrated.

---

## Key Files to Know

**Main Orchestrator:**
- `VideoProcessorViewModel.swift` - Runs entire workflow

**GPMF Integration:**
- `GPMFParserService.swift` - Has mock + real implementation instructions

**UI Entry:**
- `ContentView.swift` - Main interface with 3 tabs

**Settings:**
- `ExportSettings.swift` - All user configuration options

**Processing:**
- `VideoSegmentService.swift` - Extracts clips
- `OverlayRenderService.swift` - Adds overlays
- `SpeedAnalysisService.swift` - Analyzes speed
- `PisteIdentificationService.swift` - Identifies slopes

---

## Git Commands

```bash
# See all work done
git log --oneline

# View file
git show HEAD:README.md

# See what changed
git diff HEAD~1 HEAD

# Browse code
code .
```

---

## Next Actions

Priority order:
1. ✅ Read this guide (you're doing it!)
2. ⬜ Add files to Xcode (Step 1)
3. ⬜ Integrate GPMF parser (Step 2)
4. ⬜ Build & test with GoPro videos
5. ⬜ (Optional) Create app icon
6. ⬜ (Optional) Create DMG

**Total time: ~30-45 minutes to working app**

---

## Support

- Detailed instructions: `README.md`
- Implementation details: `NEXT_STEPS.md`
- Original plan: `~/.claude/plans/misty-dreaming-dawn.md`
- Code comments: Extensive inline documentation

---

**You're ready to go! Start with Step 1 above.** 🚀
