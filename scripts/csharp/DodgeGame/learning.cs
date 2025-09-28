using System;
namespace DodgeGame
{
    class DodgeGameMain
    {
        static void Main()
        {
            Unit playerUnit = new Unit();

            playerUnit.unitGraphic = "@";
            playerUnit.x = 5;
            playerUnit.y = 5;

            Console.SetCursorPosition(playerUnit.x,playerUnit.y);
            Console.Write(playerUnit.unitGraphic);

            Console.SetCursorPosition(
                0,
                Console.WindowHeight-1
            );
        }
    }
}