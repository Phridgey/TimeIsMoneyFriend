# Time is Money, Friend

An auction house addon for World of Warcraft 1.12 (Turtle WoW / OctoWow), based on
[aux](https://github.com/shirsig/aux-addon-vanilla) by shirsig and its Turtle WoW
version. All credit for aux itself goes to its authors; this is a personal fork with
extra features.

Command: **`/timf`** (all of aux's usual options, plus the ones below).

## Install

Copy **both** folders into `Interface\AddOns`:

- `TimeIsMoneyFriend` – the addon itself (loads on demand).
- `TimeIsMoneyFriend_Loader` – small, always loaded: loads the addon when needed and
  records your trading stats.

If you used aux before, copy `WTF\Account\<account>\SavedVariables\aux-addon.lua` to
`TimeIsMoneyFriend.lua` in the same folder to keep your price history and settings.

## What is different from aux

**Loading only where it is needed.** The addon's price data is large, so by default it
loads only in Orgrimmar, Everlook or Gadgetzan, or when an auctioneer window opens:
during a loading screen if there is one, otherwise once you stand still for a second.
If an auctioneer window opens before it has loaded (a pet auctioneer), that visit uses
the normal window and it takes over from the next one. `/timf loading` switches to
loading it everywhere.

**Ledger tab** – daily bars of gold spent buying, deposits lost on unsold auctions, gold
from sales, items bought, auctions sold and expired, with a toggle for each, 7/14/30/90
day ranges and a net total.

**Trades tab** – every item you traded, and groups such as *Level 51-59 green armour*;
tick them to graph the lowest auction house price per day with your own purchase and
sale prices and the quantities bought and sold.

**Professions panel** – beside the Search tab: open each profession once (in town, so
the addon is loaded) and click a recipe to search its item and all its materials at
once. These searches never auto-buy.

**Post tab filters** – item type, rarity and sort order for your bag list.

**Tooltips** – a small graph of your recent searches; the per-unit value of enchanting
and crafting materials when crafted into common products (oils, elixirs, enchanted
bars and leather) against selling them as they are; two-day prices for crafting costs.

**Oils** – wizard and mana oils are priced and posted per oil (they stack on this
server), and partly used oils are never posted.

## Notes

- Stats start from when the loader is installed. Sales, won bids and expired auctions
  are counted when you take them from the mail; buyouts and deposits immediately.
- The professions panel and the Post tab filters come from another fork of aux and were
  merged into this one.
