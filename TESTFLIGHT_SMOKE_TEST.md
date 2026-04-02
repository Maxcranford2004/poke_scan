# TestFlight Smoke Test

## 1) Install / Launch
- [ ] App installs cleanly
- [ ] App launches without crash
- [ ] No placeholder text on first screen
- [ ] Navigation loads correctly

## 2) Auth
- [ ] Guest / anonymous flow works
- [ ] Sign up works
- [ ] Sign in works
- [ ] Sign out works
- [ ] Collection access behavior is correct for authenticated vs non-persistent users

## 3) Scanner
- [ ] Camera permission prompt appears with correct wording
- [ ] Photo-library permission prompt appears with correct wording
- [ ] Scan from camera works
- [ ] Scan from photo library works
- [ ] Successful scan leads to result / details cleanly
- [ ] Failed scan offers retry + manual search, with no dead end

## 4) Verified Regression Cards
- [ ] Mega Froslass ex -> correct
- [ ] Mega Dragonite ex #271/217 -> correct

## 5) Manual Search
- [ ] Search returns results
- [ ] Selecting a result opens the correct detail screen
- [ ] Browse-only behavior remains correct where intended

## 6) Card Detail
- [ ] Image loads
- [ ] Metadata renders
- [ ] eBay links / previews behave correctly
- [ ] Save / add to collection works
- [ ] Finish selection works if present
- [ ] No dead buttons

## 7) Collection / Pokédex
- [ ] Scanned card lands in the correct set slot
- [ ] Grayscale vs collected contrast is clear
- [ ] Progress updates correctly
- [ ] Achievements / XP / registration flow triggers correctly
- [ ] Firestore sync works

## 8) Performance / Stability
- [ ] No visible stutter during key transitions
- [ ] No blank screens
- [ ] No obvious layout overflow
- [ ] No crash when network is slow / unavailable
- [ ] No stuck loading states

## 9) Pre-upload Checks
- [ ] Bundle identifier confirmed in Xcode
- [ ] Signing / team / provisioning confirmed
- [ ] Icon confirmed
- [ ] Screenshots prepared
- [ ] Privacy policy URL ready
- [ ] Support URL ready
- [ ] Review notes drafted

Build tested:

Device tested:

iOS version:

Tester:

Notes / bugs found:
