"""Keep persistence assertions strict while accepting native float formatting."""
import copy
import unittest

from run import Growth


class PersistenceComparison(unittest.TestCase):
    def setUp(self):
        self.saved = dict(points={"stats": 0, "class": 0}, player={"exp": 12.379999999999999},
                          talent_levels={"T_RUSH": 1}, owned_items=[dict(name="iron greatmaul", count=1, equipped=True)])

    def test_native_float_serialization_roundoff_is_accepted(self):
        loaded = copy.deepcopy(self.saved)
        loaded["player"]["exp"] = 12.38
        self.assertTrue(Growth.persistence_equal(self.saved, loaded))

    def test_point_consumption_difference_is_rejected(self):
        loaded = copy.deepcopy(self.saved)
        loaded["points"]["class"] = 1
        self.assertFalse(Growth.persistence_equal(self.saved, loaded))

    def test_lost_talent_level_is_rejected(self):
        loaded = copy.deepcopy(self.saved)
        loaded["talent_levels"]["T_RUSH"] = 0
        self.assertFalse(Growth.persistence_equal(self.saved, loaded))

    def test_lost_or_unequipped_item_is_rejected(self):
        loaded = copy.deepcopy(self.saved)
        loaded["owned_items"][0]["equipped"] = False
        self.assertFalse(Growth.persistence_equal(self.saved, loaded))
        loaded["owned_items"] = []
        self.assertFalse(Growth.persistence_equal(self.saved, loaded))

    def test_material_experience_difference_is_rejected(self):
        loaded = copy.deepcopy(self.saved)
        loaded["player"]["exp"] = 12.381
        self.assertFalse(Growth.persistence_equal(self.saved, loaded))


if __name__ == "__main__":
    unittest.main()
