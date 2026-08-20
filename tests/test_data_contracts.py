import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = REPO_ROOT / "data"


class DataContractsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with (DATA_DIR / "map.json").open(encoding="utf-8") as file:
            cls.region_map = json.load(file)

    def test_every_country_has_a_keyword_file(self):
        for continent in self.region_map["continents"]:
            for country in continent["countries"]:
                with self.subTest(country=country["id"]):
                    keyword_file = DATA_DIR / "keywords" / country["keyword_file"]
                    self.assertTrue(keyword_file.is_file(), keyword_file)
                    self.assertTrue(keyword_file.read_text(encoding="utf-8").strip(), keyword_file)

    def test_every_city_has_a_valid_region_file(self):
        for continent in self.region_map["continents"]:
            for country in continent["countries"]:
                for state in country["states"]:
                    for city in state["cities"]:
                        with self.subTest(country=country["id"], state=state["id"], city=city["id"]):
                            region_file = (
                                DATA_DIR
                                / "regions"
                                / country["id"]
                                / state["id"]
                                / f"{city['id']}.json"
                            )
                            self.assertTrue(region_file.is_file(), region_file)
                            with region_file.open(encoding="utf-8") as file:
                                region = json.load(file)
                            google = region["google_module"]
                            trust = region["trust_module"]
                            self.assertIsInstance(google["base_lat"], (int, float))
                            self.assertIsInstance(google["base_lon"], (int, float))
                            self.assertTrue(google["lang_params"])
                            self.assertTrue(google["valid_url_suffix"])
                            self.assertGreaterEqual(len(trust["static_urls"]), 5)
                            self.assertTrue(trust["white_urls"])

    def test_new_upstream_cities_are_registered(self):
        cities = {
            (country["id"], state["id"], city["id"])
            for continent in self.region_map["continents"]
            for country in continent["countries"]
            for state in country["states"]
            for city in state["cities"]
        }
        self.assertIn(("US", "CA", "Irvine"), cities)
        self.assertIn(("US", "NY", "Buffalo"), cities)


if __name__ == "__main__":
    unittest.main()
