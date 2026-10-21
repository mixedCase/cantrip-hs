-- A script of two modules. `Greet` sits beside this file in the same directory.
import Cantrip
import Greet (greeting)

main :: IO ()
main = script $ \argv -> echo (greeting (fromMaybe "world" (listToMaybe argv)))
